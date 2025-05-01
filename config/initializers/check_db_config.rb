# config/initializers/check_db_config.rb

puts "
--- Checking Database Config at Boot Time ---"
puts "Environment: #{Rails.env}"

begin
  # Get the configuration Rails has resolved for the current environment
  db_config = Rails.configuration.database_configuration[Rails.env]
  
  if db_config
    puts "Database Config Loaded Successfully."
    # Be careful about logging sensitive parts like password in production
    # Log adapter, host, database name which are usually safe and helpful
    puts "Adapter: #{db_config['adapter']}"
    puts "Host: #{db_config['host']}"
    puts "Port: #{db_config['port']}"
    puts "Database: #{db_config['database']}"
    puts "Username: #{db_config['username']}"
    # Check if it seems to be using the DATABASE_URL (often lacks explicit keys)
    puts "URL Present in Config?: #{db_config.key?('url')}"
    puts "DATABASE_URL Env Var: #{ENV['DATABASE_URL'] ? 'Set' : 'Not Set or Empty'}"
  else
    puts "Database Config NOT FOUND for environment: #{Rails.env}"
  end
rescue => e
  puts "Error retrieving database configuration at boot time."
  puts "Error: #{e.class} - #{e.message}"
end

puts "--- End Database Config Check at Boot Time ---
" 