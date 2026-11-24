module Berth
  module Config
    # The JSON a site app loads with `berth config export --site SITE --json`.
    #
    # MIRROR: BerthApp/BerthApp/Models/SiteConfig.swift
    # (docs/contract.md, "Config export"; pinned by fixtures/export.json)
    module Export
      extend self

      def to_json(model : Model, only : String? = nil) : String
        sites = only ? [model.site!(only)] : model.sites
        JSON.build(indent: "  ") do |json|
          json.object do
            json.field "version", model.version
            json.field "source", model.source.label
            json.field "path", model.path.to_s
            json.field("sites") do
              json.object do
                sites.each { |site| json.field(site.id) { self.site(json, site) } }
              end
            end
            json.field "warnings", model.warnings
          end
        end
      end

      def site(json : JSON::Builder, site : Site) : Nil
        json.object { fields(json, site) }
      end

      def fields(json : JSON::Builder, site : Site) : Nil
        json.field "site", site.id
        json.field "bundle_id", site.bundle_id
        json.field "name", site.name
        json.field "url", site.url
        json.field "keep", site.keep
        json.field "icon", site.icon.try(&.to_s)
        json.field("badge") do
          if title = site.badge_title
            json.object { json.field "title", title }
          else
            json.null
          end
        end
        json.field "handles", site.handles
        json.field "mailto", site.mailto
        json.field "notifications", site.notifications
        json.field "launch_at_login", site.launch_at_login
        json.field("signin") do
          json.object do
            site.signin.each do |login, steps|
              json.field(login) { json.array { steps.each { |step| self.step(json, step) } } }
            end
          end
        end
      end

      def step(json : JSON::Builder, step : Step) : Nil
        json.object do
          json.field "flow", step.flow
          json.field "item", step.item
          json.field "email_from", step.email_from
        end
      end
    end
  end
end
