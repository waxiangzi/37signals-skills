ActiveRecord::Schema[8.0].define(version: 2026_01_01_000000) do
  create_table "posts", force: :cascade do |t|
    t.string "title", null: false
    t.text "body"
    t.datetime "published_at"
    t.timestamps
  end

  create_table "comments", force: :cascade do |t|
    t.references "post", null: false, foreign_key: true
    t.text "body", null: false
    t.datetime "notified_at"
    t.timestamps
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", null: false
    t.index ["name"], unique: true
  end

  create_table "taggings", force: :cascade do |t|
    t.references "post", null: false, foreign_key: true
    t.references "tag", null: false, foreign_key: true
  end
end
