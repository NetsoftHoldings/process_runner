# frozen_string_literal: true

require 'climate_control'

module ClimateControlSupport
  def with_modified_env(options, &block)
    raise ArgumentError, 'block required' unless block_given?

    ::ClimateControl.modify(options, &block)
  end
end

RSpec.configure do |c|
  c.include ClimateControlSupport
end
