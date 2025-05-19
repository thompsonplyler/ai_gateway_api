class ChangeLyricSetStatusToInteger < ActiveRecord::Migration[7.1]
  def change
    change_column :lyric_sets, :status, :integer, using: 'status::integer', default: 0
  end
end
