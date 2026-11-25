import Foundation

/// The JavaScript `signin.fill` runs in the page, through
/// `callAsyncJavaScript` in an isolated content world: the page shares the
/// DOM with it but cannot reach its functions. It knows no selector of its
/// own; FlowSpec passes them in. It defines `berthSignin(request)`, where
/// `request.op` is:
///
/// - `observe`: `{host, marker, username, password, code}`, each field the
///   selector of its first visible match, or null.
/// - `fill`: sets `request.fills` (`[{field, value}]`) the way React and
///   Angular forms accept, then submits the last; returns
///   `{filled: [{field, selector}], submitted, missing}`.
/// - `choose`: on an account chooser, clicks `request.identifier`'s entry or
///   the button to use another account; returns `{clicked}`.
///
/// Its results carry selectors, never values.
enum SigninScript {
    /// The body `callAsyncJavaScript` runs, with `request` as its argument.
    static var body: String { source + "\nreturn await berthSignin(request);" }

    // js-validate
    static let source = """
    const berthSignin = async function (request) {
      const spec = request.spec;

      function visible(node) {
        if (!node || node.disabled || node.type === "hidden") return false;
        if (node.closest("[aria-hidden='true']")) return false;
        const rect = node.getBoundingClientRect();
        if (rect.width < 1 || rect.height < 1) return false;
        const style = window.getComputedStyle(node);
        return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
      }

      function find(selectors, scope) {
        for (const selector of selectors) {
          let nodes = [];
          try {
            nodes = (scope || document).querySelectorAll(selector);
          } catch (error) {
            continue;
          }
          for (const node of nodes) {
            if (visible(node)) return { node: node, selector: selector };
          }
        }
        return null;
      }

      function words(text) {
        return (text || "").replace(/\\s+/g, " ").trim().toLowerCase();
      }

      function findByLabel(labels, scope) {
        const wanted = labels.map(words);
        const nodes = (scope || document).querySelectorAll(
          "button, input[type=submit], input[type=button], [role=button], [role=link], a"
        );
        for (const node of nodes) {
          if (!visible(node)) continue;
          const text = words(node.tagName === "INPUT" ? node.value : node.textContent);
          const index = wanted.indexOf(text);
          if (index >= 0) return { node: node, label: labels[index] };
        }
        return null;
      }

      // The prototype's setter, not the element's: React tracks an input's
      // value through the element's own, and would ignore the change.
      function setValue(input, value) {
        input.focus();
        const prototype = input instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, "value").set.call(input, value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }

      function submit(field, input) {
        const scopes = input.form ? [input.form, document] : [document];
        for (const scope of scopes) {
          const button = find(field.submit, scope);
          if (button) {
            button.node.click();
            return "button " + button.selector;
          }
        }
        for (const scope of scopes) {
          const labelled = findByLabel(field.labels, scope);
          if (labelled) {
            labelled.node.click();
            return "button labelled " + labelled.label;
          }
        }
        if (input.form && typeof input.form.requestSubmit === "function") {
          input.form.requestSubmit();
          return "the form";
        }
        const enter = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true };
        input.dispatchEvent(new KeyboardEvent("keydown", enter));
        input.dispatchEvent(new KeyboardEvent("keyup", enter));
        return "the Enter key";
      }

      function pause(milliseconds) {
        return new Promise(function (resolve) { setTimeout(resolve, milliseconds); });
      }

      if (request.op === "observe") {
        const result = { host: location.hostname, marker: null };
        for (const selector of spec.markers) {
          try {
            if (document.querySelector(selector)) {
              result.marker = selector;
              break;
            }
          } catch (error) {}
        }
        for (const name of ["username", "password", "code"]) {
          const found = find(spec.fields[name].selectors);
          result[name] = found ? found.selector : null;
        }
        return result;
      }

      if (request.op === "choose") {
        const chooser = spec.chooser;
        if (!chooser) return { clicked: null };
        if (request.identifier) {
          for (const node of document.querySelectorAll("[" + chooser.attribute + "]")) {
            if (visible(node) && words(node.getAttribute(chooser.attribute)) === words(request.identifier)) {
              node.click();
              return { clicked: "the account's entry" };
            }
          }
        }
        const other = findByLabel(chooser.labels);
        if (other) {
          other.node.click();
          return { clicked: "button labelled " + other.label };
        }
        return { clicked: null };
      }

      if (request.op === "fill") {
        const found = [];
        for (const fill of request.fills) {
          const match = find(spec.fields[fill.field].selectors);
          if (!match) return { filled: [], submitted: null, missing: fill.field };
          found.push({ field: fill.field, value: fill.value, match: match });
        }
        for (const item of found) setValue(item.match.node, item.value);
        await pause(150);
        const last = found[found.length - 1];
        const submitted = submit(spec.fields[last.field], last.match.node);
        return {
          filled: found.map(function (item) { return { field: item.field, selector: item.match.selector }; }),
          submitted: submitted,
          missing: null
        };
      }

      return null;
    };
    """
}
