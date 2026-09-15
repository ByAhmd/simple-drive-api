# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_15_104445) do
  create_table "blob_contents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["storage_key"], name: "index_blob_contents_on_storage_key", unique: true
  end

  create_table "blobs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier", limit: 1024, null: false
    t.bigint "size", null: false
    t.string "storage_backend", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_blobs_on_identifier", unique: true
    t.index ["storage_key"], name: "index_blobs_on_storage_key", unique: true
    t.check_constraint "size >= 0", name: "blobs_size_non_negative"
  end

  create_table "pending_uploads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "storage_backend", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_pending_uploads_on_created_at"
    t.index ["storage_key"], name: "index_pending_uploads_on_storage_key", unique: true
  end
end
