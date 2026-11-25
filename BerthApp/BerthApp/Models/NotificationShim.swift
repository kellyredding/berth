import Foundation

/// The `window.Notification` a site app gives its pages when the site turns
/// notifications on. WebKit's own web view has none. It runs at document start
/// in the page's own content world, main frame only, since the page itself
/// constructs `Notification`s, and only on a host `keep` matches.
///
/// It posts to the `berthNotifications` script message handler, which
/// replies:
///
/// - `{op: "request"}` → `"granted"`, `"denied"` or `"default"`.
/// - `{op: "show", id, title, body, tag, silent}` → whether macOS took it.
/// - `{op: "close", id, tag}` → nothing.
///
/// `icon`, `data` and the rest stay on the page's object. The app reaches
/// the page through `window.__berthNotification`: `clicked(id)` fires that
/// notification's `click`, and `permission(value)` follows a change made in
/// System Settings.
/// What the shim is given: the site's hosts and the page's permission.
struct NotificationShimState: Equatable {
    let keep: [String]
    let permission: NotificationPermission

    /// None when the site leaves notifications off.
    static func wanted(notifications: Bool, keep: KeepList, authorization: NotificationAuthorization) -> NotificationShimState? {
        notifications ? NotificationShimState(keep: keep.patterns, permission: authorization.pagePermission) : nil
    }
}

enum NotificationShim {
    static let handlerName = "berthNotifications"

    /// The user script: the shim, called with the site's hosts and the
    /// permission macOS has given so far, inside a function so it adds no
    /// global but the two it means to.
    static func userScript(keep: [String], permission: NotificationPermission) -> String {
        let config: [String: Any] = ["handler": handlerName, "keep": keep, "permission": permission.rawValue]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return "(function () {\n\(source)\nberthNotificationShim(\(String(decoding: data, as: UTF8.self)));\n})();"
    }

    /// `callAsyncJavaScript`'s body for a click, with `id` as its argument:
    /// whether the page still has that notification.
    static var clickBody: String { clickSource + "\nreturn berthNotificationClicked(id);" }

    // js-validate
    static let clickSource = """
    const berthNotificationClicked = function (id) {
      const notifications = window.__berthNotification;
      return notifications ? notifications.clicked(id) : false;
    };
    """

    /// `callAsyncJavaScript`'s body for a new permission, with `permission`
    /// as its argument.
    // js-validate
    static let permissionBody = """
    const notifications = window.__berthNotification;
    if (notifications) notifications.permission(permission);
    """

    // js-validate
    static let source = """
    function berthNotificationShim(config) {
      "use strict";
      const handlers = window.webkit && window.webkit.messageHandlers;
      const channel = handlers && handlers[config.handler];
      if (!channel) return;

      // KeepList's rule: exact hosts, and *. patterns for subdomains only.
      function kept(hostname) {
        let host = String(hostname || "").toLowerCase();
        if (host.endsWith(".")) host = host.slice(0, -1);
        if (!host) return false;
        return config.keep.some(function (pattern) {
          if (pattern.startsWith("*.")) {
            const suffix = pattern.slice(1);
            return host.length > suffix.length && host.endsWith(suffix);
          }
          return host === pattern;
        });
      }
      if (!kept(location.hostname)) return;

      const PERMISSIONS = ["default", "denied", "granted"];
      const EVENTS = ["click", "close", "show", "error"];
      // The app keeps as many for clicks; older ones can no longer be clicked.
      const LIVE_LIMIT = 200;
      let permission = PERMISSIONS.includes(config.permission) ? config.permission : "default";
      const states = new WeakMap();
      const live = new Map();
      const prefix = Math.random().toString(36).slice(2, 10);
      let counter = 0;

      function send(message) {
        try {
          return Promise.resolve(channel.postMessage(message));
        } catch (error) {
          return Promise.reject(error);
        }
      }

      function fire(notification, type) {
        notification.dispatchEvent(new Event(type));
      }

      function text(value) {
        return value === undefined || value === null ? "" : String(value);
      }

      class Notification extends EventTarget {
        constructor(title, options) {
          super();
          if (arguments.length < 1) {
            throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          }
          const given = options || {};
          const state = {
            id: prefix + "-" + (++counter),
            title: String(title),
            body: text(given.body),
            tag: text(given.tag),
            icon: text(given.icon),
            badge: text(given.badge),
            image: text(given.image),
            lang: text(given.lang),
            dir: given.dir || "auto",
            silent: given.silent === undefined || given.silent === null ? null : Boolean(given.silent),
            requireInteraction: Boolean(given.requireInteraction),
            renotify: Boolean(given.renotify),
            data: given.data === undefined ? null : given.data,
            timestamp: typeof given.timestamp === "number" ? given.timestamp : Date.now(),
            handlers: {},
            closed: false
          };
          states.set(this, state);
          const self = this;
          for (const type of EVENTS) {
            this.addEventListener(type, function (event) {
              const handler = state.handlers[type];
              if (typeof handler === "function") handler.call(self, event);
            });
          }
          if (permission !== "granted") {
            setTimeout(function () { fire(self, "error"); }, 0);
            return;
          }
          live.set(state.id, this);
          if (live.size > LIVE_LIMIT) live.delete(live.keys().next().value);
          send({ op: "show", id: state.id, title: state.title, body: state.body, tag: state.tag, silent: state.silent === true })
            .then(function (shown) {
              if (state.closed) return;
              if (!shown) live.delete(state.id);
              fire(self, shown ? "show" : "error");
            }, function () {
              live.delete(state.id);
              fire(self, "error");
            });
        }

        close() {
          const state = states.get(this);
          if (!state || state.closed) return;
          state.closed = true;
          live.delete(state.id);
          send({ op: "close", id: state.id, tag: state.tag }).catch(function () {});
          fire(this, "close");
        }

        static get permission() {
          return permission;
        }

        static get maxActions() {
          return 0;
        }

        static requestPermission(callback) {
          const asked = send({ op: "request" }).then(function (result) {
            if (PERMISSIONS.includes(result)) permission = result;
            return permission;
          }, function () {
            return permission;
          });
          if (typeof callback === "function") asked.then(callback);
          return asked;
        }
      }

      for (const name of ["title", "body", "tag", "icon", "badge", "image", "lang", "dir", "silent",
                          "requireInteraction", "renotify", "data", "timestamp"]) {
        Object.defineProperty(Notification.prototype, name, {
          configurable: true,
          enumerable: true,
          get: function () { return states.get(this)[name]; }
        });
      }
      Object.defineProperty(Notification.prototype, "actions", {
        configurable: true,
        enumerable: true,
        get: function () { return []; }
      });
      for (const type of EVENTS) {
        Object.defineProperty(Notification.prototype, "on" + type, {
          configurable: true,
          enumerable: true,
          get: function () { return states.get(this).handlers[type] || null; },
          set: function (handler) { states.get(this).handlers[type] = typeof handler === "function" ? handler : null; }
        });
      }

      Object.defineProperty(window, "__berthNotification", {
        value: Object.freeze({
          clicked: function (id) {
            const notification = live.get(id);
            if (notification) fire(notification, "click");
            return Boolean(notification);
          },
          permission: function (value) {
            if (PERMISSIONS.includes(value)) permission = value;
          }
        })
      });
      Object.defineProperty(window, "Notification", {
        value: Notification,
        configurable: true,
        enumerable: false,
        writable: true
      });
    }
    """
}
