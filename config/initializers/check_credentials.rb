# config/initializers/check_credentials.rb

puts "
--- Checking Credentials at Boot Time ---"
puts "Environment: #{Rails.env}"

begin
  # Try accessing the config directly; rescue if credentials aren't ready/decryptable
  credentials_hash = Rails.application.credentials.config
  
  puts "Credentials Loaded Successfully."
  puts "Credentials Hash Keys: #{credentials_hash.keys.inspect}"
  puts "Has :openai key?: #{credentials_hash.key?(:openai)}"
  
  if credentials_hash.key?(:openai)
    puts "Value for :openai type: #{credentials_hash[:openai].class}"
    if credentials_hash[:openai].is_a?(Hash)
      puts "Has :openai[:api_key]?: #{credentials_hash[:openai].key?(:api_key)}"
    end
  end
rescue => e
  # Catch errors like missing key file or decryption issues during boot
  puts "Credentials could not be loaded/decrypted at boot time."
  puts "Error: #{e.class} - #{e.message}"
end

puts "--- End Credentials Check at Boot Time ---
" 