name = 'parallel_cucumber'
require "./lib/#{name}/version"

Gem::Specification.new name, ParallelCucumber::VERSION do |spec|
  spec.name = 'parallel_cucumber'
  spec.authors = 'Alexander Bayandin'
  spec.email = 'a.bayandin@gmail.com'
  spec.summary = 'Run cucumber in parallel'
  spec.homepage = 'https://github.com/bayandin/parallel_cucumber'
  spec.license = 'MIT'

  spec.files = Dir['{lib}/**/*.rb', 'bin/*', 'README.md']
  spec.executables = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = 'lib'

  spec.add_runtime_dependency 'parallel', '~> 1.6'
  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'cucumber'
end
