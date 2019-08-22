module ParallelCucumber
  class Job
    RUN_TESTS = 'run_tests'.freeze
    PRECHECK = 'precheck'.freeze
    DIE = 'die'.freeze

    attr_accessor :type, :details
    def initialize(type, details = nil)
      @type = type
      @details = details
    end
  end
end
