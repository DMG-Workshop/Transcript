// GENERATED CONTENT — the JSON literal below is the single source of truth for the
// NoteDocument shape. `docs/schemas/note-document.schema.json` is exported from it by
// `dart run tool/export_schema.dart`, and `test/schema_sync_test.dart` fails the build if
// the two drift apart.

import 'dart:convert';

/// The canonical NoteDocument JSON Schema, in the strict-mode-compatible subset:
/// every property appears in `required`, optionality is a nullable type union, and
/// `additionalProperties` is false throughout. Provider-specific dialects are derived
/// from this by [SchemaDialect]; never hand-maintain a second copy.
const String noteDocumentSchemaJson = r'''
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://transcript.app/schemas/note-document/v1.json",
  "title": "NoteDocument",
  "description": "Canonical structured output produced from a transcript. Every LLM provider adapter must fill this exact shape. Written in the strict-mode-compatible subset: every property is listed in `required`, optionality is expressed as a nullable type union, and additionalProperties is false throughout.",
  "type": "object",
  "additionalProperties": false,
  "required": ["meta", "participants", "sections", "decisions", "openQuestions", "tasks", "risks", "timelineAnchors"],
  "properties": {
    "meta": {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "summary", "recordingType", "language", "extractionConfidence"],
      "properties": {
        "title": { "type": "string", "description": "Six words or fewer. Derived from content, never generic." },
        "summary": { "type": "string", "description": "2-4 sentences. What happened and what changed as a result." },
        "recordingType": { "type": "string", "enum": ["meeting", "standup", "interview", "lecture", "voice_memo", "call", "other"] },
        "language": { "type": "string", "description": "BCP-47 tag of the dominant spoken language, e.g. en-US." },
        "extractionConfidence": { "type": "string", "enum": ["high", "medium", "low"], "description": "low when audio was unclear, heavily cross-talked, or too short to structure." }
      }
    },
    "participants": {
      "type": "array",
      "description": "Only people actually identifiable from the transcript. Empty array if none are named.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "displayName", "aliases", "role"],
        "properties": {
          "id": { "type": "string", "description": "Stable slug, e.g. p_sarah_chen." },
          "displayName": { "type": "string" },
          "aliases": { "type": "array", "items": { "type": "string" }, "description": "Other forms heard in audio: nicknames, speaker labels, misheard variants." },
          "role": { "type": ["string", "null"], "description": "Only if stated aloud." }
        }
      }
    },
    "sections": {
      "type": "array",
      "description": "The narrative body of the notes, in the order topics were discussed.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["heading", "bullets", "sourceRef"],
        "properties": {
          "heading": { "type": "string" },
          "bullets": { "type": "array", "items": { "type": "string" }, "description": "Each bullet a complete, self-contained statement. No filler, no 'the team discussed'." },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    },
    "decisions": {
      "type": "array",
      "description": "Things that were settled. A decision requires that an option was chosen over alternatives, not merely mentioned.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "statement", "rationale", "decidedBy", "sourceRef"],
        "properties": {
          "id": { "type": "string" },
          "statement": { "type": "string" },
          "rationale": { "type": ["string", "null"] },
          "decidedBy": { "type": ["string", "null"], "description": "participants[].id, or null if unattributable." },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    },
    "openQuestions": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "question", "raisedBy", "sourceRef"],
        "properties": {
          "id": { "type": "string" },
          "question": { "type": "string" },
          "raisedBy": { "type": ["string", "null"] },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    },
    "tasks": {
      "type": "array",
      "description": "Action items. This array feeds the Kanban board and the Gantt chart.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "title", "detail", "assigneeId", "assigneeRaw", "status", "priority", "estimate", "startDate", "dueDate", "dateBasis", "dependsOn", "epic", "sourceRef"],
        "properties": {
          "id": { "type": "string", "description": "Stable slug, e.g. t_migrate_auth_service." },
          "title": { "type": "string", "description": "Imperative and specific: 'Migrate auth service to OIDC', not 'Auth stuff'." },
          "detail": { "type": ["string", "null"], "description": "Only context that was actually spoken." },
          "assigneeId": { "type": ["string", "null"], "description": "participants[].id when the owner is a known participant." },
          "assigneeRaw": { "type": ["string", "null"], "description": "The name as spoken, when it does not resolve to a participant." },
          "status": { "type": "string", "enum": ["todo", "in_progress", "blocked", "done"], "description": "Default 'todo'. Use 'done' only when completion was reported in the recording." },
          "priority": { "type": "string", "enum": ["low", "medium", "high", "critical"], "description": "Default 'medium' unless urgency was expressed." },
          "estimate": {
            "type": ["object", "null"],
            "additionalProperties": false,
            "required": ["value", "unit"],
            "description": "Only when a duration or size was stated aloud.",
            "properties": {
              "value": { "type": "number" },
              "unit": { "type": "string", "enum": ["hours", "days", "weeks", "points"] }
            }
          },
          "startDate": { "type": ["string", "null"], "description": "ISO-8601 date (YYYY-MM-DD), resolved against referenceDate." },
          "dueDate": { "type": ["string", "null"], "description": "ISO-8601 date (YYYY-MM-DD), resolved against referenceDate." },
          "dateBasis": {
            "type": "string",
            "enum": ["explicit", "inferred", "absent"],
            "description": "explicit = a concrete date or day was spoken. inferred = resolved from relative language such as 'end of next sprint'. absent = no timing was discussed; both date fields must be null. The UI renders these three differently and never invents the third."
          },
          "dependsOn": { "type": "array", "items": { "type": "string" }, "description": "Other tasks[].id values. Include ONLY dependencies stated aloud ('we can't start X until Y ships'). Never infer ordering from topic sequence." },
          "epic": { "type": ["string", "null"], "description": "Workstream or theme name, only if the transcript groups work that way." },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    },
    "risks": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "description", "severity", "sourceRef"],
        "properties": {
          "id": { "type": "string" },
          "description": { "type": "string" },
          "severity": { "type": "string", "enum": ["low", "medium", "high"] },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    },
    "timelineAnchors": {
      "type": "array",
      "description": "Fixed dates mentioned that are not themselves tasks: launch dates, sprint boundaries, deadlines, holidays. Rendered as milestone markers on the Gantt.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["label", "date", "sourceRef"],
        "properties": {
          "label": { "type": "string" },
          "date": { "type": "string", "description": "ISO-8601 date." },
          "sourceRef": { "$ref": "#/$defs/sourceRef" }
        }
      }
    }
  },
  "$defs": {
    "sourceRef": {
      "type": "object",
      "additionalProperties": false,
      "required": ["startMs", "endMs", "quote"],
      "description": "Provenance. Every extracted item must cite the transcript span it came from. This is the anti-hallucination mechanism and it powers tap-to-play in the UI.",
      "properties": {
        "startMs": { "type": ["integer", "null"], "description": "Offset into the recording. Null only when the transcript carried no timestamps." },
        "endMs": { "type": ["integer", "null"] },
        "quote": { "type": "string", "description": "A verbatim span from the transcript, 3-25 words, that justifies this item. Must appear in the transcript character-for-character." }
      }
    }
  }
}
''';

Map<String, dynamic>? _cached;

/// The canonical schema, decoded. Cached — callers must not mutate the result.
Map<String, dynamic> get noteDocumentSchema =>
    _cached ??= json.decode(noteDocumentSchemaJson) as Map<String, dynamic>;

/// Schema version, surfaced on every stored NoteDocument so old notes stay explainable.
const String noteSchemaVersion = 'note-document/v1';
