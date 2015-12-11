require 'cucumber'

module ParallelCucumber
  module Bugs
    class << self
      def known_issues(options)
        expand_and_junit(options[:cucumber_options])
      end

      private

      def expand_and_junit(cucumber_options)
        if !(cucumber_options =~ /(^|\s)(-x|--expand)(\s|$)/).nil? && cucumber_version < Gem::Version.new('2.0.0.rc.5')
          warn('Junit report does not work with -x|--expand option: https://github.com/cucumber/cucumber-ruby/issues/124')
        end
      end

      def cucumber_version
        Gem::Version.new(Cucumber::VERSION)
      end
    end # self
  end # Bugs
end # ParallelCucumber