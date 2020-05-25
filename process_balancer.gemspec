# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'process_runner/version'

Gem::Specification.new do |spec|
  spec.name    = 'process_balancer'
  spec.version = ProcessRunner::VERSION
  spec.authors = ['Edward Rudd']
  spec.email   = ['urkle@outoforder.cc']

  spec.summary     = 'A self-balancing long-running job runner'
  spec.description = 'A self-balancing long-running job runner'
  spec.homepage    = 'http://github.com/'
  spec.license     = 'LGPLv3'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(spec|bin)/}) || f[0] == '.' }
  end

  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.5.0'

  spec.add_development_dependency 'bundler', '~> 1.17'
  spec.add_development_dependency 'climate_control', '~> 0.2'
  spec.add_development_dependency 'fakefs', '~> 1.2.2'
  spec.add_development_dependency 'mock_redis', '~> 0.23'
  spec.add_development_dependency 'rake', '~> 11.0'
  spec.add_development_dependency 'redis-namespace', '~> 1.7'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rspec_junit_formatter', '~> 0.4'
  spec.add_development_dependency 'rubocop', '~> 0.83.0'
  spec.add_development_dependency 'rubocop-rspec', '~> 1.39.0'
  spec.add_development_dependency 'simplecov', '~> 0.12'

  spec.add_dependency 'concurrent-ruby', '~> 1.1'
  spec.add_dependency 'connection_pool', '~> 2.2', '>= 2.2.2'
  spec.add_dependency 'redis', '>= 3.3.5', '< 5'
end
