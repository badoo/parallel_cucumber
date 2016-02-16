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
        def dry_run_report(options, args)
          options = options.dup
          options = expand_profiles(options) unless config_file.nil?
          options = remove_formatters(options)
          content = nil

          Tempfile.open(%w(dry-run .json)) do |f|
            dry_run_options = "--dry-run --format json --out #{f.path}"

            cmd = "cucumber #{options} #{dry_run_options} #{args.join(' ')}"
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

        def parse_json_report(json_report)
          report = JSON.parse(json_report)
          report.map do |feature|
            next if feature['elements'].nil?
            background = {}
            feature['elements'].map do |scenario|
              if scenario['type'] == 'background'
                background = scenario
                next
              end
              steps = [background['steps'], scenario['steps']].flatten.compact
              status = case
                       when steps.map { |step| step['result'] }.all? { |result| result['status'] == 'skipped' }
                         Status::SKIPPED
                       when steps.map { |step| step['result'] }.any? { |result| result['status'] == 'failed' }
                         Status::FAILED
                       when steps.map { |step| step['result'] }.all? { |result| result['status'] == 'passed' }
                         Status::PASSED
                       when steps.map { |step| step['result'] }.any? { |result| result['status'] == 'undefined' }
                         Status::UNKNOWN
                       else
                         Status::UNKNOWN
                       end
              { "#{feature['uri']}:#{scenario['line']}".to_sym => status }
            end
          end.flatten.compact.inject(&:merge)
        end

        private

        def expand_profiles(options)
          config = YAML.load(ERB.new(File.read(config_file)).result)
          _expand_profiles(options, config)
        end

        def config_file
          Dir.glob('{,.config/,config/}cucumber{.yml,.yaml}').first
        end

        def _expand_profiles(options, config)
          profiles = options.scan(/(?:^|\s)((?:--profile|-p)\s+[\S]+)/)
          profiles.map(&:first).each do |profile|
            option = profile.gsub(/(--profile|-p)\s+/, '')
            options.gsub!(profile, _expand_profiles(config[option], config))
          end
          options.strip
        end

        def remove_formatters(options)
          options.gsub(/(--format|-f|--out|-o)\s+[\S]+/, '').gsub(/--dry-run\s+/, '')
        end
      end
    end
  end
end
