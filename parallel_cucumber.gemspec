name = 'parallel_cucumber'
require "./lib/#{name}/version"

Gem::Specification.new name, ParallelCucumber::VERSION do |spec|
  spec.name = 'parallel_cucumber'
  spec.authors = 'Alexander Bayandin'
  spec.email = 'a.bayandin@gmail.com'
  spec.summary = 'Run cucumber in parallel'
  spec.description = 'Our own parallel cucumber with queue and workers'
  spec.homepage = 'https://github.com/badoo/parallel_cucumber'
  spec.license = 'MIT'

  spec.files = Dir['{lib}/**/*.rb', 'bin/*', 'README.md']
  spec.executables = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = 'lib'

  spec.add_runtime_dependency 'cucumber', '~> 2'
  spec.add_runtime_dependency 'parallel', '~> 1.6'
  spec.add_runtime_dependency 'redis', '~> 3.2'
  spec.add_development_dependency 'overcommit', '~> 0.31'
  spec.add_development_dependency 'rubocop', '~> 0.37'
end
