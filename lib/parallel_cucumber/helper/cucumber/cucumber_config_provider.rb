require 'cucumber/cli/configuration'
require 'cucumber/configuration'
require 'open3'
require 'yaml'

module ParallelCucumber
  module Helper
    module CucumberConfigProvider
      class << self
        # Creates ::Cucumber::Configuration from cucumber_options string
        # Invokes new process Ruby in order to push environment that would be resolved when creating Cucumber configuration
        # @param [String] options_string string that is passed by --cucumber-options
        # @param [Hash] batch_env environment for running a cucumber test in a child process
        # @return [Hash] Cucumber configuration normalized to Hash
        def config_from_options(options_string, batch_env)
          script = <<~EOSCRIPT
            require "cucumber/cli/configuration"
            require "cucumber/configuration"
            require "yaml"

            cli_config = ::Cucumber::Cli::Configuration.new($stdout, $stderr).tap do |config|
              config.parse!(ARGV)
            end

            cucumber_config = ::Cucumber::Configuration.new(cli_config).to_hash

            cucumber_config.delete(:event_bus)
            cucumber_config.delete(:profile_loader)
            cucumber_config.delete(:retry_total)

            puts(YAML.dump(cucumber_config))
          EOSCRIPT

          o, e, s = Open3.capture3(batch_env, "bundle exec ruby -e '#{script}' -- #{options_string}")

          unless s.success?
            raise(ArgumentError, "Failed to create Cucumber configuration from options string.\n#{o}\n#{e}")
          end

          YAML.unsafe_load(o)
        end
      end
    end

    class CucumberCliHelper
      def initialize(cucumber_config)
        @config = cucumber_config
      end

      def tags
        @config[:tag_expressions].sort.uniq.map do |tag|
          if tag.include?(' ')
            "-t \"#{tag}\""
          else
            "-t #{tag}"
          end
        end
      end

      def formats
        @config[:formats].map do |format|
          if format.last.nil? || format.last.is_a?(IO)
            "--format #{format.first}"
          else
            "--format #{format.first} --out #{format.last}"
          end
        end
      end

      def requires
        @config[:require].map { |required_resource| "-r #{required_resource}" }
      end

      def excludes
        @config[:excludes].map { |excluded| "--exclude #{excluded.source.gsub('\\','') }" }
      end

      def env_vars
        @config[:env_vars] || {}
      end

      def paths
        @config[:paths] || []
      end

      def additional_args
        %w[--no-color --strict --publish-quiet]
      end

    end
  end
end
