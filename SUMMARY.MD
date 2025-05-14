# Project Summary: AI Gateway API

## 1. Project Overview

This is a Ruby on Rails application designed to act as a middleware API for orchestrating multi-stage AI-driven tasks. It primarily functions as an API, so all interactions and verifications should be done via API calls (e.g., using Postman) or, as a last resort, the Rails console. **There are no HTML views.**

**Core Technologies:**
*   Ruby on Rails (API-only)
*   PostgreSQL (Database)
*   Sidekiq (Background Job Processing)
*   Redis (Sidekiq backend, Caching)
*   Faraday (HTTP client for external API calls)

## 2. Core AI Workflows

### 2.1. Presentation Evaluation Workflow ("AI Shark Tank")

This workflow processes uploaded presentation files (PPT, PPTX, PDF) through a multi-agent evaluation pipeline.

**Key Features & Flow:**
*   **File Intake:** Accepts presentation uploads.
*   **Multi-Agent Simulation:** Each presentation is evaluated by multiple simulated "agents," each with distinct personalities, voices, and evaluation criteria defined in `config/initializers/agents.rb`.
*   **Pipeline Stages (per agent):**
    1.  **LLM-based Text Evaluation:** Generates a textual critique using the OpenAI Assistants API.
    2.  **Text-to-Speech (TTS):** Converts the text evaluation to an MP3 audio file using the ElevenLabs API (unique voice per agent).
    3.  **Text-to-Video (TTV):** (Supported but can be disabled) Combines an agent's image with their audio to produce an MP4 video using the Hedra API.
*   **Configurable Pipeline:** Each evaluation request can specify whether to skip TTS (`skip_tts`) and/or TTV (`skip_ttv`) stages.
*   **Status Tracking & Retry:** Robust job and per-agent evaluation status tracking. Failed or stuck steps can be retried.
*   **Error Handling:** Differentiates between retryable (e.g., HTTP 5xx, 429) and non-retryable (e.g., client-side 4xx) errors from external APIs, integrating with Sidekiq's retry mechanisms.

**Data Models:**
*   `EvaluationJob`: Manages the overall process for one uploaded file. Stores the file (ActiveStorage), skip flags, and overall status. Has many `Evaluation` records.
*   `Evaluation`: Represents one agent's pipeline for an `EvaluationJob`. Stores agent identifier, text output, status for each stage (LLM, TTS, TTV), and links to generated audio/video files (ActiveStorage).

**Background Jobs (Sidekiq):**
*   `LlmEvaluationJob`: Fetches agent instructions, calls OpenAI Assistants API, saves text, enqueues `TtsGenerationJob` (if not skipped).
*   `TtsGenerationJob`: Uses text and voice ID, calls ElevenLabs API, saves audio, enqueues `TtvGenerationJob` (if not skipped).
*   `TtvGenerationJob`: Uses audio and image, calls Hedra API, saves video.
*   All jobs call `EvaluationJob#check_completion` to update the parent job's status.

### 2.2. Quest Generation Workflow

This workflow generates in-game quest candidates through a generate-supervise-refine loop using the OpenAI Responses API.

**Key Features & Flow:**
*   **Initial Generation:** An AI generates quest dialogue (intro, completion message) and chooses variables (species, hat, mood, item) based on a detailed prompt and predefined variable lists. Output is a structured JSON object.
*   **Supervisory Review:** A second AI call (acting as a QA Narrative Designer) reviews the generated quest against quality criteria, outputting an approval status and feedback in a structured JSON format. For testing, this stage can be made randomly approving/rejecting.
*   **Refinement Loop:**
    *   If a quest `needs_revision`, feedback from the supervisor is used to construct a new prompt for the AI to revise the quest.
    *   The revised quest is then sent back for another round of supervision.
    *   This loop continues until the quest is approved (or a max attempt limit is reached - *future consideration*).
*   **Contextual Chaining:** Uses `previous_response_id` from the OpenAI Responses API to link conversational turns (e.g., refinement is a response to supervisor feedback).
*   **Attempt Tracking:** Counts refinement attempts for each quest candidate.
*   **Feedback History:** Stores all supervisory notes for a quest candidate.

**Data Model:**
*   `QuestCandidate`: Stores chosen variables, intro/complete messages, `raw_api_response_id` (for the latest generation/refinement), `status` (enum: `pending_review`, `needs_revision`, `approved`), supervisor details (`supervisor_raw_api_response_id`, `supervisor_approved`), `approved_at`, `refinement_attempts` (integer, default 0), and `supervisory_notes_history` (jsonb array).

**Core Service:**
*   `OpenaiResponsesService`: Handles all communication with the OpenAI `POST /v1/responses` endpoint, including managing structured JSON output requests using specific `text.format` parameters.

**Background Jobs (Sidekiq):**
*   `GenerateQuestCandidateJob`: Initiates quest generation, creates `QuestCandidate` (status `pending_review`), enqueues `SuperviseQuestCandidateJob`.
*   `SuperviseQuestCandidateJob`: Sends quest for review, updates `QuestCandidate` with feedback/status, appends to `supervisory_notes_history`. If `needs_revision`, increments `refinement_attempts` and enqueues `RefineQuestCandidateJob`.
*   `RefineQuestCandidateJob`: Takes feedback, prompts AI for revision, updates `QuestCandidate` with new dialogue, resets status to `pending_review`, and re-enqueues `SuperviseQuestCandidateJob`.

**JSON Schemas:**
*   Defined in `config/initializers/openai_quest_schemas.rb` for `QUEST_GENERATION_SCHEMA` and `SUPERVISOR_REVIEW_SCHEMA`.

## 3. API Endpoints (Namespace: `/api/v1`)

**Presentation Evaluation Workflow:**
*   `POST /evaluation_jobs`: Upload a presentation file (PPT, PPTX, PDF) and optionally `skip_tts`, `skip_ttv`. Triggers the evaluation pipeline.
*   `GET  /evaluation_jobs/:id`: Get detailed status of an `EvaluationJob` and its per-agent progress.
*   `POST /evaluation_jobs/:id/retry_failed`: Retry failed or stuck evaluations within a job.

**Text Evaluation Workflow (Simplified):**
*   `POST /text_evaluation_jobs`: (Details to be filled if this is a distinct, active workflow)
*   `GET  /text_evaluation_jobs/:id`: (Details to be filled)

**Quest Generation Workflow:**
*   `POST /quest_candidates/generate`: Triggers the `GenerateQuestCandidateJob`.
*   `GET  /quest_candidates`: Lists all generated `QuestCandidate` records (supports pagination).
*   `GET  /quest_candidates/:id`: Shows a specific `QuestCandidate` record.

**User Management & Authentication:**
*   `POST /users`: User registration.
*   `POST /session`: User login (create session/token).
*   `DELETE /session`: User logout (destroy session/token).

**AI Tasks (Generic):**
*   `POST /ai_tasks`: (Details to be filled)
*   `GET /ai_tasks`: (Details to be filled)
*   `GET /ai_tasks/:id`: (Details to be filled)

**Health Checks:**
*   `GET /health`
*   `GET /up` (Rails default)

## 4. Key Configuration Files

*   `config/initializers/agents.rb`: Defines agent characteristics for the Presentation Evaluation workflow.
*   `config/initializers/openai_quest_schemas.rb`: Defines JSON schemas for the Quest Generation workflow.
*   `config/routes.rb`: Defines all API endpoints and the Sidekiq Web UI route (`/sidekiq`).
*   `config/credentials.yml.enc`: Stores API keys for external services (OpenAI, ElevenLabs, Hedra). Prioritized for API key access within services.
*   `config/database.yml`: PostgreSQL connection details.
*   `app/services/openai_responses_service.rb`: Wrapper for OpenAI Responses API.

## 5. Challenges, Gotchas & Key Learnings for Future AI/Developer

This section consolidates insights gained during development, particularly useful for onboarding or troubleshooting.

*   **External API Specificity (OpenAI Responses API):**
    *   The `POST /v1/responses` endpoint's structure for requesting structured JSON output (`text: { format: { type: "json_schema", name: "...", schema: {...}, strict: true } }`) was discovered through iterative trial-and-error based on API error messages. It differs from other OpenAI API patterns (e.g., Chat Completions' `response_format`). Assume nothing; test parameter structures meticulously.
    *   `previous_response_id` is essential for contextual conversations.
    *   The `instructions` parameter is non-inheriting when `previous_response_id` is used, which is powerful for multi-stage agent interactions.

*   **Rails Schema Integrity & Caching:**
    *   **Symptom**: `undefined method` errors for new model attributes in Sidekiq jobs or API responses, even after running migrations and basic server restarts.
    *   **Root Cause**: `db/schema.rb` not accurately reflecting the database state due to migrations not applying fully/correctly, or running processes (web server, Sidekiq) using cached schema information.
    *   **Diagnosis**: Direct inspection of `db/schema.rb` is paramount. If it's incorrect, migrations are the problem. If `db/schema.rb` *is* correct but errors persist, ensure full restarts of *all* Rails processes (including Spring if used, though determined not to be in use here).
    *   **Resolution**: For persistent schema discrepancies, a `rails db:drop db:create db:migrate` or a targeted "corrector" migration might be necessary to force the schema into the correct state. Always verify `db/schema.rb` is regenerated correctly after migrations.

*   **Sidekiq Environment Consistency:**
    *   Sidekiq workers run in separate processes. Ensure they have access to the same environment variables (like API keys) and Rails application context (including initializers and credentials) as the main web server process.
    *   For API keys, using `Rails.application.credentials` is more robust than relying solely on `ENV` variables for Sidekiq jobs that load the full Rails environment.

*   **CORS Errors:** For APIs intended to be called from browser-based frontends, ensure `config/initializers/cors.rb` is correctly configured.

*   **Sidekiq Error Handling & Retries:** Differentiate `Faraday::Error` types in background jobs. Re-raise server-side errors (5xx, 429) to leverage Sidekiq's retry mechanisms; handle client-side errors (4xx) by failing the job explicitly if they are non-recoverable.

*   **Enum Predicate Methods:** Rails enums defined with a hash do not automatically create predicate methods (e.g., `object.processing_evaluations?`). Use direct status comparison (`object.status == 'processing_evaluations'`).

## 6. How to Rebuild/Understand This Project

1.  **Setup Basic Rails API**: `rails new ai_gateway_api --api -d postgresql`. Add `sidekiq`, `redis`, `faraday`.
2.  **Define Models**: Create ActiveRecord models as described in section 2 (e.g., `EvaluationJob`, `Evaluation`, `QuestCandidate`, `User`, `ApiToken`, etc.) by generating migrations and defining associations/enums.
3.  **Configure External Services**: Set up `config/credentials.yml.enc` for OpenAI, ElevenLabs, Hedra API keys.
4.  **Implement Core Services**: Create `OpenaiResponsesService` (and any other wrappers for ElevenLabs/Hedra).
5.  **Develop API Controllers & Routes**: Implement controllers in `app/controllers/api/v1/` for each resource as listed in section 3, defining actions and JSON rendering. Set up `config/routes.rb`.
6.  **Implement Background Jobs**: Create Sidekiq jobs for each asynchronous task (e.g., `LlmEvaluationJob`, `GenerateQuestCandidateJob`, etc.), detailing their API calls, data manipulation, status updates, and enqueuing of subsequent jobs.
7.  **Add Configuration**: Create initializers like `agents.rb` and `openai_quest_schemas.rb`.
8.  **Iteratively Test**: Use an API client (Postman) to test each endpoint and the full job workflows, monitoring Sidekiq and Rails logs closely.