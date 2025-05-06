# Project Summary: AI Presentation Evaluation Pipeline

## Project Overview

This is a Ruby on Rails application designed to process uploaded presentations (supporting PPT, PPTX, and PDF formats) through a multi-stage AI evaluation pipeline. The system simulates evaluations from multiple distinct "agents," each with its own personality and voice. Key components include:

*   **LLM-based Text Evaluation:** Each agent uses an LLM (OpenAI Assistants API) to generate a textual evaluation of the uploaded presentation based on predefined instructions.
*   **Text-to-Speech (TTS) Generation:** The textual evaluation from each agent is converted into speech (MP3) using the ElevenLabs API, with unique voice IDs per agent.
*   **Text-to-Video (TTV) Generation:** (Currently disabled by default for testing/cost reasons, but supported) Combines an agent's image with their generated audio to produce a video evaluation (MP4) using the Hedra API.
*   **Job Management & Status Tracking:** The system provides robust job status tracking, a mechanism to retry failed steps, and allows for per-request configuration of the pipeline stages.

All processing stages are handled by background jobs using Sidekiq.

## Recent Features Added

1.  **Centralized Agent Configuration:**
    *   Agent-specific details (OpenAI instructions, ElevenLabs voice IDs, image paths for TTV) were moved from being hardcoded in individual job files to a central configuration file (`config/initializers/agents.rb`). This greatly simplifies management and updates of agent characteristics.

2.  **Per-Job Configurable Pipeline (Skip Flags):**
    *   Boolean flags `skip_tts` and `skip_ttv` were added to the `EvaluationJob` model (and its database table), defaulting to `false`.
    *   API clients can now specify these flags in the `POST /api/v1/evaluation_jobs` request to control which stages of the pipeline are executed for that specific job (e.g., LLM only, or LLM+TTS only).
    *   This replaced a previous global toggle for the TTV step.

3.  **Enhanced Job Status Reporting (`show` Endpoint):**
    *   The `GET /api/v1/evaluation_jobs/:id` endpoint was significantly improved to provide a more detailed and accurate JSON response:
        *   Includes the job-specific `skip_tts` and `skip_ttv` flags to indicate the requested pipeline for that job.
        *   Returns granular, stage-specific statuses for each agent (e.g., `llm_complete`, `tts_processing`, `ttv_skipped`, `llm_failed`) within distinct arrays: `individual_evaluations`, `individual_audio`, and `individual_videos`.
        *   Provides direct URLs to the originally uploaded file and any generated audio/video artifacts via ActiveStorage.

4.  **Robust Retry Mechanism for Failed/Stuck Evaluations:**
    *   A new endpoint `POST /api/v1/evaluation_jobs/:id/retry_failed` was implemented.
    *   This allows for retrying individual `Evaluation` records within a parent `EvaluationJob` that have either:
        *   Explicitly failed (status: `failed`).
        *   Become "stuck" in an intermediate processing state (`evaluating`, `generating_audio`, `generating_video`) for longer than a defined threshold for that specific stage (LLM: 90s, TTS: 2m, TTV: 5m).
    *   The retry logic intelligently restarts the processing for an agent from the point of failure (e.g., if TTS failed, it retries TTS with existing LLM text, not the entire LLM step again).
    *   The check for stuck TTV steps respects the `skip_ttv` flag of the parent job.

5.  **PDF File Upload Support:**
    *   The backend controllers (`EvaluationJobsController`, `TextEvaluationJobsController`) were updated to validate and accept `application/pdf` MIME type, in addition to the original PPT/PPTX formats.

6.  **Improved Background Job Error Handling (LLM Job):**
    *   The error handling within `LlmEvaluationJob` was refined. It now distinguishes between:
        *   Retryable `Faraday::Error` exceptions (e.g., `Faraday::ServerError` for HTTP 5xx, `Faraday::TooManyRequestsError` for HTTP 429). These are re-raised to allow Sidekiq's `retry_on` mechanism to handle them automatically.
        *   Non-retryable `Faraday::Error` exceptions (e.g., client-side 4xx errors), which cause the specific evaluation to be marked as `failed` immediately.

## Challenges Faced & Error Messages Addressed

1.  **CORS Errors:**
    *   **Message:** `Access to fetch at '...' has been blocked by CORS policy: No 'Access-Control-Allow-Origin' header is present...`
    *   **Resolution:** The `config/initializers/cors.rb` file was uncommented and configured to explicitly allow requests from the frontend application's origin (e.g., `http://localhost:5173`).

2.  **Sidekiq Retries Not Triggering for LLM Job API Errors:**
    *   **Symptom:** HTTP 500 errors from the OpenAI API within the `LlmEvaluationJob` were not resulting in job retries, despite `retry_on Faraday::ServerError` being configured.
    *   **Cause:** A broad `rescue Faraday::Error` block within the job was catching these exceptions and handling them (by marking the evaluation as failed), thus preventing Sidekiq's retry mechanism from seeing the original error.
    *   **Resolution:** The `rescue Faraday::Error` block was modified to check the specific type of `Faraday::Error`. If it's a `Faraday::ServerError` or `Faraday::TooManyRequestsError`, the exception is re-raised. Other `Faraday::Error` types are handled locally by failing the evaluation.

3.  **Premature Job Completion with Skipped Steps:**
    *   **Symptom:** An `EvaluationJob` with `skip_tts: true` and `skip_ttv: true` was being marked `completed` even if one of its child `Evaluation` records (for a specific agent) was still actively processing the LLM step (status: `evaluating`).
    *   **Cause:** The `EvaluationJob#check_completion` method incorrectly determined the `expected_terminal_status` for child evaluations as `'evaluating'` when both TTS and TTV were skipped. This matched the *in-progress* state of the LLM job.
    *   **Resolution:**
        *   `LlmEvaluationJob` was updated: if `skip_tts` is true, a successful LLM evaluation now sets the child `Evaluation` status to `'generating_audio'` (conceptually, the state just before the skipped TTS step).
        *   `EvaluationJob#check_completion` was updated: if `skip_tts` and `skip_ttv` are true, the `expected_terminal_status` for children is now `'generating_audio'`. This ensures all LLM jobs must truly finish.

4.  **Incorrect Retry of "Completed" Skipped Steps:**
    *   **Symptom:** The `retry_failed` endpoint was retrying evaluations that had successfully completed their LLM and TTS stages but were in the `generating_video` state because the TTV step was (globally or per-job) disabled.
    *   **Cause:** The logic for identifying "stuck" jobs considered `generating_video` a stuck state if `updated_at` was old, without fully accounting for the TTV step being intentionally skipped.
    *   **Resolution:** The query in `retry_failed` was refined to only consider an evaluation stuck in `generating_video` if the `skip_ttv` flag for that specific `EvaluationJob` is `false`.

5.  **`undefined method 'processing_evaluations?'` in Model:**
    *   **Error:** Occurred within `EvaluationJob#check_completion`.
    *   **Cause:** Rails `enum` defined with a hash (e.g., `enum status: { pending: 0, ... }`) does not automatically generate predicate methods like `processing_evaluations?`.
    *   **Resolution:** The check was changed from `return unless processing_evaluations?` to `return unless status == 'processing_evaluations'`.

## High-Level Project Description (for Rebuilding)

This system is a Ruby on Rails application using Sidekiq for background job processing. It's designed to take an uploaded presentation file, process it through a series of AI services for evaluation by multiple simulated "agents," and make the results available via an API.

**Core Components & Flow:**

1.  **Models:**
    *   `EvaluationJob`: Manages the overall process for a single uploaded file. Tracks overall status (`pending`, `processing_evaluations`, `completed`, `failed`), stores the original file (ActiveStorage), and holds boolean flags (`skip_tts`, `skip_ttv`) to control pipeline stages. Has many `Evaluation` records.
    *   `Evaluation`: Represents a single agent's evaluation pipeline for the parent `EvaluationJob`. Stores `agent_identifier`, its specific processing status (e.g., `pending`, `evaluating`, `generating_audio`, `video_generated`, `failed`), the LLM's text output, and attached audio/video files (ActiveStorage).

2.  **API (`Api::V1` Namespace):**
    *   **`POST /evaluation_jobs`:** Accepts a file (PPT, PPTX, PDF) and optional `skip_tts`, `skip_ttv` boolean parameters. Creates an `EvaluationJob` record and associated child `Evaluation` records (one per agent), then enqueues the initial `LlmEvaluationJob` for each child.
    *   **`GET /evaluation_jobs/:id`:** Returns the detailed status of the `EvaluationJob`, including overall status, skip flags, links to uploaded/generated files, and per-agent detailed progress for LLM, TTS, and TTV stages.
    *   **`POST /evaluation_jobs/:id/retry_failed`:** Identifies failed or "stuck" child `Evaluation` records within the job and re-enqueues the appropriate background job to restart processing from the point of failure.

3.  **Background Jobs (Sidekiq):**
    *   **`LlmEvaluationJob`:**
        *   Receives an `Evaluation` ID.
        *   Retrieves agent-specific instructions (from `config/initializers/agents.rb`).
        *   Calls OpenAI Assistants API.
        *   Saves text result to `Evaluation#text_result`. Sets `Evaluation#status`.
        *   If parent `EvaluationJob#skip_tts` is `false`, enqueues `TtsGenerationJob`.
        *   Calls `EvaluationJob#check_completion` on the parent.
    *   **`TtsGenerationJob`:**
        *   Receives an `Evaluation` ID.
        *   Uses `Evaluation#text_result` and agent-specific voice ID (from `config/initializers/agents.rb`).
        *   Calls ElevenLabs API.
        *   Attaches audio MP3 to `Evaluation#audio_file`. Sets `Evaluation#status`.
        *   If parent `EvaluationJob#skip_ttv` is `false`, enqueues `TtvGenerationJob`.
        *   Calls `EvaluationJob#check_completion` on the parent.
    *   **`TtvGenerationJob`:** (Currently, enqueuing this job is commented out in `TtsGenerationJob`)
        *   Receives an `Evaluation` ID.
        *   Uses `Evaluation#audio_file` and agent-specific image path (from `config/initializers/agents.rb`).
        *   Calls Hedra API.
        *   Attaches video MP4 to `Evaluation#video_file`. Sets `Evaluation#status` to `video_generated`.
        *   Calls `EvaluationJob#check_completion` on the parent.
    *   All jobs are configured with Sidekiq's `retry_on` for specific `Faraday::Error` types (e.g., server errors, rate limits).

4.  **Key Configuration Files:**
    *   `config/initializers/agents.rb`: Central store for agent personalities, voice IDs, image paths.
    *   `config/routes.rb`: Defines API endpoints and the Sidekiq Web UI route.
    *   `config/credentials.yml.enc`: Stores API keys for external services (OpenAI, ElevenLabs, Hedra).
    *   `config/initializers/cors.rb`: Manages Cross-Origin Resource Sharing.
    *   Database Migrations: To create `evaluation_jobs` (with status, error_message, skip_tts, skip_ttv) and `evaluations` (with agent_identifier, status, error_message, text_result) tables, and ActiveStorage tables.

5.  **Main Logic/Functionality:**
    *   **File Intake & Validation:** Handles PPT/PPTX/PDF uploads.
    *   **Pipeline Orchestration:** `EvaluationJob` model's callbacks and the individual background jobs manage the flow through LLM, TTS, and TTV stages.
    *   **Skip Logic:** Conditional enqueuing of jobs based on `skip_tts` and `skip_ttv` flags on the `EvaluationJob`.
    *   **Completion Tracking:** The `EvaluationJob#check_completion` method is crucial. It's called by each job after its step to determine if the overall parent job can be marked `completed` or `failed`, considering the skip flags and the status of all sibling evaluations.
    *   **Error Handling:** Each job has `rescue` blocks. Retryable API errors are re-raised for Sidekiq. Non-retryable errors or other exceptions lead to the `Evaluation` (and potentially `EvaluationJob`) being marked `failed` with an error message.

To rebuild this, one would establish the Rails application with Sidekiq, define the database schema for jobs and evaluations, implement the API controllers for job creation and status polling, and then create each background job, carefully handling API interactions, status updates, and the conditional logic for enqueuing subsequent steps and checking for overall job completion based on the per-job skip flags. 