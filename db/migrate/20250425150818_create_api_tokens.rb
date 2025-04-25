class CreateApiTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token
      t.datetime :expires_at

      t.timestamps
    end
    add_index :api_tokens, :token, unique: true
  end
end
