require_relative '../cucumber'
require 'test/unit'

class CucumberTest < Test::Unit::TestCase
  def test_argument_mapping
    s, m = ParallelCucumber::Helper::Cucumber.batch_mapped_files('--out foo/bar -o wib/ble', 'ARGH', {})
    assert_equal('--out ARGH/bar -o ARGH/ble', s)
    assert_equal({ 'foo/bar' => 'ARGH/bar', 'wib/ble' => 'ARGH/ble' }, m)
  end
end
