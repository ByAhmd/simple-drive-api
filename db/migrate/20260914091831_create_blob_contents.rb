class CreateBlobContents < ActiveRecord::Migration[8.1]
  def change
    create_table :blob_contents do |t|
      t.string :storage_key, null: false
      t.binary :data, null: false
      t.timestamps

      t.index :storage_key, unique: true
    end
  end
end
