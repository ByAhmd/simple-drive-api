class CreatePendingUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_uploads do |t|
      t.string :storage_key, null: false
      t.string :storage_backend, null: false
      t.timestamps

      t.index :storage_key, unique: true
      t.index :created_at
    end
  end
end
