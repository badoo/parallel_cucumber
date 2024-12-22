name = 'parallel_cucumber'
require "./lib/#{name}/version"

Gem::Specification.new name, ParallelCucumber::VERSION do |spec|
  spec.name        = name
  spec.authors     = ['Alexander Bayandin']
  spec.email       = 'a.bayandin@gmail.com'
  spec.summary     = 'Run cucumber in parallel'
  spec.description = 'Our own parallel cucumber with queue and workers'
  spec.homepage    = 'https://github.com/badoo/parallel_cucumber'
  spec.license     = 'MIT'

  spec.files         = Dir['{lib}/**/*.rb', 'bin/*', 'README.md']
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = 'lib'

  spec.required_ruby_version = '>= 3.3.6' # Inherited from runtime dependencies

  spec.add_runtime_dependency 'cucumber', '~> 9.2.0'
  spec.add_runtime_dependency 'parallel', '~> 1.26.3'
  spec.add_runtime_dependency 'redis', '5.3.0'
  spec.add_development_dependency 'overcommit', '~> 0.64.1'
  spec.add_development_dependency 'rubocop', '~> 1.69.2'
end
