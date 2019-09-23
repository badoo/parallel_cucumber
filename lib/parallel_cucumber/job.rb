module ParallelCucumber
  class Job
    RUN_TESTS = :run_tests
    PRECHECK  = :precheck
    DIE       = :die

    attr_accessor :type, :details
    def initialize(type, details = nil)
      @type = type
      @details = details
    end
  end
end
