module Panomosity
  module Utils
    def calculate_average_and_std(name: 'value', values: [], logger: nil)
      average_value = values.reduce(:+).to_f / values.count
      logger.debug "average #{name}: #{average_value}" if logger
      value_std = Math.sqrt(values.map { |v| (v - average_value) ** 2 }.reduce(:+) / (values.count - 1))
      logger.debug "#{name} std: #{value_std}" if logger
      [average_value, value_std]
    end
  end
end