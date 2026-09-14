class CreateBlobs < ActiveRecord::Migration[8.1]
  def change
    create_table :blobs do |t|
      t.string :identifier, null: false, limit: 1024
      t.bigint :size, null: false
      t.string :storage_backend, null: false
      t.string :storage_key, null: false
      t.timestamps

      t.index :identifier, unique: true
      t.index :storage_key, unique: true
      t.check_constraint "size >= 0", name: "blobs_size_non_negative"
    end
  end
end
