require "bundler/setup"
require "json_schema/faker"

if ENV["DEBUG"]
  require "pry"

  require "logger"
  logger = Logger.new($stderr)
  logger.level = case ENV["DEBUG"]
                 when "1"; Logger::INFO
                 when "2"; Logger::DEBUG
                 else      Logger::WARN
                 end
  JsonSchema::Faker::Configuration.logger = logger
end

Dir["spec/support/*.rb"].sort.each {|file| load file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  config.example_status_persistence_file_path = "spec/examples.txt"

  config.disable_monkey_patching!

  #config.warnings = true

  config.order = :random

  Kernel.srand config.seed
end
