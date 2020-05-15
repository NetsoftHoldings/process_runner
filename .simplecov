# frozen_string_literal: true

SimpleCov.configure do
  if ENV['CIRCLE_ARTIFACTS']
    dir = File.join(ENV['CIRCLE_ARTIFACTS'], 'coverage')
    coverage_dir(dir)
  end
  add_filter '/spec/'
  add_filter '/lib/process_balancer/version.rb'
  add_filter '/lib/process_balancer/private/'
end
