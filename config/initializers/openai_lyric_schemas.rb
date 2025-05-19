# config/initializers/openai_lyric_schemas.rb

# Schema for the AI generating the song lyrics
LYRIC_GENERATION_SCHEMA = {
  type: :object,
  properties: {
    suggested_song_title: {
      type: :string,
      description: "A creative and fitting title for the song based on the lyrics."
    },
    lyrics_body: {
      type: :string,
      description: "The full body of the song lyrics, including verses, chorus, bridge (if any), and outro (if any). Use newline characters (\n) for line breaks and double newlines (\n\n) to separate stanzas (e.g., verse, chorus)."
    }
  },
  required: ["suggested_song_title", "lyrics_body"],
  additionalProperties: false
}.freeze

# Schema for the supervisory AI to critique the generated lyrics
LYRIC_SUPERVISION_SCHEMA = {
  type: :object,
  properties: {
    lyrics_approved: {
      type: :boolean,
      description: "True if the lyrics meet the quality standard and no further revisions are required (average score > 90), false otherwise."
    },
    overall_critique: {
      type: :string,
      description: "A general critique of the lyrics, summarizing their strengths and weaknesses based on the rubric. If requesting a start over, explain why briefly."
    },
    points_for_revision: {
      type: :array,
      description: "Specific points or sections in the lyrics that need revision if not approved and not starting over. This should be empty if lyrics_approved is true or request_to_start_over is true.",
      items: {
        type: :object,
        properties: {
          section_reference: {
            type: :string,
            description: "The part of the lyrics being referred to (e.g., 'Verse 1, Line 3', 'Chorus', 'Overall Theme')."
          },
          issue_identified: {
            type: :string,
            description: "A clear description of the issue related to the rubric criteria (e.g., 'Emotional resonance is low here', 'Lacks depth, too superficial', 'Wordplay is clichéd or description is on-the-nose', 'Theme from prompt is repeated too directly')."
          },
          suggestion_for_improvement: {
            type: :string,
            description: "A concrete suggestion on how to improve this specific point to meet rubric standards."
          }
        },
        required: ["section_reference", "issue_identified", "suggestion_for_improvement"],
        additionalProperties: false
      }
    },
    rubric_scores: {
      type: :object,
      description: "Scores based on the defined rubric (1-100 for each criterion).",
      properties: {
        emotional_resonance: { type: :integer, description: "Score (1-100) for emotional resonance." },
        depth_and_meaning: { type: :integer, description: "Score (1-100) for depth, meaning, and working on multiple levels." },
        wordplay_and_imagery: { type: :integer, description: "Score (1-100) for sophisticated wordplay, vivid imagery, and avoidance of on-the-nose descriptions." },
        thematic_development: { type: :integer, description: "Score (1-100) for creative thematic development beyond the initial prompt, using associations and avoiding direct repetition." }
      },
      required: ["emotional_resonance", "depth_and_meaning", "wordplay_and_imagery", "thematic_development"],
      additionalProperties: false
    },
    average_score: {
      type: :number,
      description: "The average of the four rubric scores. If this is > 90, lyrics_approved should be true. If < 50, request_to_start_over should be true."
    },
    request_to_start_over: {
      type: :boolean,
      description: "True if the average score is < 50, indicating a full rewrite is needed. False otherwise."
    }
  },
  required: [
    "lyrics_approved",
    "overall_critique",
    "points_for_revision",
    "rubric_scores",
    "average_score",
    "request_to_start_over"
  ],
  additionalProperties: false
}.freeze 