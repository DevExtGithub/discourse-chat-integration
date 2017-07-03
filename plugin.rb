# name: discourse-chat-integration
# about: This plugin integrates discourse with a number of chat providers
# version: 0.1
# url: https://github.com/discourse/discourse-chat-integration

enabled_site_setting :chat_integration_enabled

register_asset "stylesheets/chat-integration-admin.scss"

# Site setting validators must be loaded before initialize
require_relative "lib/validators/chat_integration_slack_enabled_setting_validator"

after_initialize do

  module ::DiscourseChat
    PLUGIN_NAME = "discourse-chat-integration".freeze

    class Engine < ::Rails::Engine
      engine_name DiscourseChat::PLUGIN_NAME
      isolate_namespace DiscourseChat
    end

    def self.plugin_name
      DiscourseChat::PLUGIN_NAME
    end

    def self.pstore_get(key)
      PluginStore.get(self.plugin_name, key)
    end

    def self.pstore_set(key, value)
      PluginStore.set(self.plugin_name, key, value)
    end

    def self.pstore_delete(key)
      PluginStore.remove(self.plugin_name, key)
    end
  end

  require_relative "lib/discourse_chat/provider"
  require_relative "lib/discourse_chat/manager"
  require_relative "lib/discourse_chat/rule"

  module ::Jobs
    class NotifyChats < Jobs::Base
      def execute(args)
        return if not SiteSetting.chat_integration_enabled? # Plugin may have been disabled since job triggered

        ::DiscourseChat::Manager.trigger_notifications(args[:post_id])
      end
    end
  end

  DiscourseEvent.on(:post_created) do |post| 
    if SiteSetting.chat_integration_enabled?
      # This will run for every post, even PMs. Don't worry, they're filtered out later.
      Jobs.enqueue_in(SiteSetting.chat_integration_delay_seconds.seconds,
          :notify_chats,
          post_id: post.id
        )
    end
  end

  class ::DiscourseChat::ChatController < ::ApplicationController
    requires_plugin DiscourseChat::PLUGIN_NAME

    def respond
      render
    end

    def list_providers
      providers = ::DiscourseChat::Provider.enabled_providers.map {|x| {name: x::PROVIDER_NAME, id: x::PROVIDER_NAME}}
      render json:providers, root: 'providers'
    end

    def list_rules
      providers = ::DiscourseChat::Provider.enabled_providers.map {|x| x::PROVIDER_NAME}

      requested_provider = params[:provider]

      if providers.include? requested_provider
        rules = DiscourseChat::Rule.all_for_provider(requested_provider)
      else
        raise Discourse::NotFound
      end

      filter_order = ["watch", "follow", "mute"]
      rules = rules.sort_by{ |r| [r.channel, filter_order.index(r.filter), r.category_id] } 

      render_serialized rules, DiscourseChat::RuleSerializer, root: 'rules'
    end

    def create_rule
      begin
        rule = DiscourseChat::Rule.new()
        hash = params.require(:rule)

        if not rule.update(hash)
          raise Discourse::InvalidParameters, 'Rule is not valid'
        end

        render_serialized rule, DiscourseChat::RuleSerializer, root: 'rule'
      rescue Discourse::InvalidParameters => e
        render json: {errors: [e.message]}, status: 422
      end
    end

    def update_rule
      begin
        rule = DiscourseChat::Rule.find(params[:id].to_i)
        hash = params.require(:rule)

        if not rule.update(hash)
          raise Discourse::InvalidParameters, 'Rule is not valid'
        end

        render_serialized rule, DiscourseChat::RuleSerializer, root: 'rule'
      rescue Discourse::InvalidParameters => e
        render json: {errors: [e.message]}, status: 422
      end
    end

    def destroy_rule
      rule = DiscourseChat::Rule.find(params[:id].to_i)

      rule.destroy

      render json: success_json
    end
  end

  class DiscourseChat::RuleSerializer < ActiveModel::Serializer
    attributes :id, :provider, :channel, :category_id, :tags, :filter
  end

  require_dependency 'admin_constraint'


  add_admin_route 'chat_integration.menu_title', 'chat'

  DiscourseChat::Engine.routes.draw do
    get "" => "chat#respond"
    get '/providers' => "chat#list_providers"
    
    get '/rules' => "chat#list_rules"
    put '/rules' => "chat#create_rule"
    put '/rules/:id' => "chat#update_rule"
    delete '/rules/:id' => "chat#destroy_rule"

    get "/:provider" => "chat#respond"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseChat::Engine, at: '/admin/plugins/chat', constraints: AdminConstraint.new
  end

end
