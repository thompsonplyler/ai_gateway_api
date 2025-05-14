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

ActiveRecord::Schema[7.1].define(version: 2025_05_13_235446) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_tasks", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "prompt"
    t.string "status", default: "queued"
    t.text "result"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_ai_tasks_on_user_id"
  end

  create_table "api_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_api_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "evaluation_jobs", force: :cascade do |t|
    t.string "status"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "skip_tts", default: false
    t.boolean "skip_ttv", default: false
  end

  create_table "evaluations", force: :cascade do |t|
    t.bigint "evaluation_job_id", null: false
    t.string "agent_identifier"
    t.text "text_result"
    t.string "status"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["evaluation_job_id"], name: "index_evaluations_on_evaluation_job_id"
  end

  create_table "quest_candidates", force: :cascade do |t|
    t.string "chosen_variables_species"
    t.string "chosen_variables_hat"
    t.string "chosen_variables_mood"
    t.string "chosen_variables_item_needed"
    t.text "quest_intro"
    t.text "quest_complete_message"
    t.string "raw_api_response_id"
    t.string "status"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "supervisor_raw_api_response_id"
    t.boolean "supervisor_approved"
    t.integer "refinement_attempts", default: 0, null: false
    t.jsonb "supervisory_notes_history", default: [], null: false
  end

  create_table "text_evaluation_jobs", force: :cascade do |t|
    t.string "status"
    t.text "text_result"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "text_evaluations", force: :cascade do |t|
    t.bigint "text_evaluation_job_id", null: false
    t.string "agent_identifier"
    t.string "status"
    t.text "text_result"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["text_evaluation_job_id"], name: "index_text_evaluations_on_text_evaluation_job_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_tasks", "users"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "evaluations", "evaluation_jobs"
  add_foreign_key "text_evaluations", "text_evaluation_jobs"
end
