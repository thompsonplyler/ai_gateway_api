class CreateLyricSets < ActiveRecord::Migration[7.1]
  def change
    create_table :lyric_sets do |t|
      t.text :topic
      t.text :current_lyrics
      t.string :status
      t.integer :refinement_attempts, default: 0
      t.datetime :approved_at
      t.jsonb :revision_history

      t.timestamps
    end
  end
end
