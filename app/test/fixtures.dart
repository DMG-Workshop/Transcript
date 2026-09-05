import 'dart:convert';

import 'package:transcript_app/src/data/database.dart' as db;

/// A note with one dated task, one undated task, a decision and an unclear-audio flag —
/// enough to exercise every branch the note screen renders.
Map<String, dynamic> noteJson() => {
      'meta': {
        'title': 'Auth migration kickoff',
        'summary': 'The team agreed to retire the legacy session store before launch.',
        'recordingType': 'meeting',
        'language': 'en-US',
        'extractionConfidence': 'high',
      },
      'participants': [
        {'id': 'p_priya', 'displayName': 'Priya', 'aliases': <String>[], 'role': null},
      ],
      'sections': [
        {
          'heading': 'Auth migration',
          'bullets': [
            'The legacy session store is being retired before launch.',
            'Priya owns the migration.',
          ],
          'sourceRef': {
            'startMs': 12000,
            'endMs': 30000,
            'quote': 'we need to get off the legacy session store',
          },
        },
      ],
      'decisions': [
        {
          'id': 'd_retire',
          'statement': 'Retire the legacy session store before launch.',
          'rationale': null,
          'decidedBy': 'p_priya',
          'sourceRef': {
            'startMs': 30000,
            'endMs': 42000,
            'quote': 'we are retiring it before launch, agreed',
          },
        },
      ],
      'openQuestions': [],
      'tasks': [
        {
          'id': 't_migrate',
          'title': 'Migrate the auth service off the legacy session store',
          'detail': null,
          'assigneeId': 'p_priya',
          'assigneeRaw': null,
          'status': 'todo',
          'priority': 'high',
          'estimate': null,
          'startDate': null,
          'dueDate': '2026-09-18',
          'dateBasis': 'explicit',
          'dependsOn': <String>[],
          'epic': null,
          'sourceRef': {
            'startMs': 45000,
            'endMs': 58000,
            'quote': 'it has to be done by the eighteenth',
          },
        },
        {
          'id': 't_runbook',
          'title': 'Update the runbook',
          'detail': null,
          'assigneeId': null,
          'assigneeRaw': null,
          'status': 'todo',
          'priority': 'medium',
          'estimate': null,
          'startDate': null,
          'dueDate': null,
          'dateBasis': 'absent',
          'dependsOn': <String>[],
          'epic': null,
          'sourceRef': {
            'startMs': 70000,
            'endMs': 76000,
            'quote': 'somebody should update the runbook at some point',
          },
        },
      ],
      'risks': [],
      'timelineAnchors': [],
    };

db.Recording recordingRow({bool structured = true, String? overrideNote}) =>
    db.Recording(
      id: 'r_1',
      title: 'Auth migration kickoff',
      startedAt: DateTime(2026, 9, 5, 10, 30),
      durationMs: 95000,
      audioPath: '/tmp/rec.wav',
      transcriptionProviderId: 'on-device',
      structuringProviderId: 'anthropic',
      structuringModel: 'claude-opus-5',
      noteJson: structured ? (overrideNote ?? jsonEncode(noteJson())) : null,
      noteSchemaVersion: 'note-document/v1',
      promptVersion: 'structuring/2026-09-05',
      inputTokens: 1840,
      outputTokens: 610,
    );
