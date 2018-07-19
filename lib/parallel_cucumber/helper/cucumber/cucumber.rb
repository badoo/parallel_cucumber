require 'English'
require 'erb'
require 'json'
require 'open3'
require 'tempfile'
require 'yaml'

module ParallelCucumber
  module Helper
    module Cucumber
      class << self
        def selected_tests(options, args_string)
          puts "selected_tests (#{options.inspect} #{args_string.inspect})"
          dry_run_report = dry_run_report(options, args_string)
          parse_json_report(dry_run_report).keys
        end

        def batch_mapped_files(options, batch, env)
          options = options.dup
          options = expand_profiles(options, env) unless config_file.nil?
          file_map = {}
          options.gsub!(/(?:\s|^)--dry-run\s+/, '')
          options.gsub!(%r{((?:\s|^)(?:--out|-o))\s+((?:\S+\/)?(\S+))}) { "#{$1} #{file_map[$2] = "#{batch}/#{$3}"}" } # rubocop:disable Style/PerlBackrefs, Metrics/LineLength
          [options, file_map]
        end

        def parse_json_report(json_report)
          report = JSON.parse(json_report, symbolize_names: true)
          report.map do |scenario, cucumber_status|
            status = case cucumber_status
                       when 'failed'
                         Status::FAILED
                       when 'passed'
                         Status::PASSED
                       when 'pending'
                         Status::PENDING
                       when 'skipped'
                         Status::SKIPPED
                       when 'undefined'
                         Status::UNDEFINED
                       when 'unknown'
                         Status::UNKNOWN
                       else
                         Status::UNKNOWN
                     end
            [scenario, status]
          end.to_h
        end

        private

        def dry_run_report(options, args_string)
          options = options.dup
          options = expand_profiles(options) unless config_file.nil?
          options = remove_formatters(options)
          options = remove_dry_run_flag(options)
          options = remove_strict_flag(options)
          content = nil

          Tempfile.open(%w(dry-run .json)) do |f|
            dry_run_options = "--dry-run --format ParallelCucumber::Helper::Cucumber::JsonStatusFormatter --out #{f.path}"

            cmd = "cucumber #{options} #{dry_run_options} #{args_string}"
            _stdout, stderr, status = Open3.capture3(cmd)
            f.close

            unless status == 0
              cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
              raise("Can't generate dry run report: #{status}:\n\t#{cmd}\n\t#{stderr}")
            end

            content = File.read(f.path)
          end
          content
        end

        def expand_profiles(options, env = {})
          mutex.synchronize do
            e = ENV.to_h
            ENV.replace(e.merge(env))
            begin
              content = ERB.new(File.read(config_file)).result
              config  = YAML.safe_load(content)
              return _expand_profiles(options, config)
            ensure
              ENV.replace(e)
            end
          end
        end

        # @return Mutex
        def mutex
          @mutex ||= Mutex.new
        end

        def config_file
          Dir.glob('{,.config/,config/}cucumber{.yml,.yaml}').first
        end

        def _expand_profiles(options, config)
          profiles = options.scan(/(?:^|\s)((?:--profile|-p)\s+[\S]+)/)
          profiles.map(&:first).each do |profile|
            option = profile.gsub(/(--profile|-p)\s+/, '')
            options.gsub!(profile, _expand_profiles(config.fetch(option), config))
          end
          options.strip
        end

        def remove_formatters(options)
          options.gsub(/(^|\s)(--format|-f|--out|-o)\s+[\S]+/, ' ')
        end

        def remove_dry_run_flag(options)
          options.gsub(/(^|\s)--dry-run(\s|$)/, ' ')
        end

        def remove_strict_flag(options)
          options.gsub(/(^|\s)(--strict|-S)(\s|$)/, ' ')
        end
      end
    end
  end
end
