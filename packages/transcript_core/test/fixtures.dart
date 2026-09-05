/// A minimal but schema-valid NoteDocument, plus the transcript it claims to come from.
///
/// Kept as JSON rather than as model objects so tests exercise the same path production
/// does: provider text -> parse -> validate -> model.
Map<String, dynamic> validNoteJson() => {
      'meta': {
        'title': 'Auth migration kickoff',
        'summary':
            'The team agreed to move the auth service off the legacy session '
                'store. Priya owns the migration and it needs to land before the launch.',
        'recordingType': 'meeting',
        'language': 'en-US',
        'extractionConfidence': 'high',
      },
      'participants': [
        {
          'id': 'p_priya',
          'displayName': 'Priya',
          'aliases': ['Prya'],
          'role': null,
        },
      ],
      'sections': [
        {
          'heading': 'Auth migration',
          'bullets': [
            'The legacy session store is being retired before launch.'
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
          'id': 'd_retire_sessions',
          'statement': 'Retire the legacy session store before launch.',
          'rationale': 'It cannot handle the expected load.',
          'decidedBy': 'p_priya',
          'sourceRef': {
            'startMs': 30000,
            'endMs': 42000,
            'quote': 'so we are retiring it before launch, agreed',
          },
        },
      ],
      'openQuestions': [],
      'tasks': [
        {
          'id': 't_migrate_auth',
          'title': 'Migrate the auth service off the legacy session store',
          'detail': null,
          'assigneeId': 'p_priya',
          'assigneeRaw': null,
          'status': 'todo',
          'priority': 'high',
          'estimate': {'value': 2, 'unit': 'weeks'},
          'startDate': null,
          'dueDate': '2026-09-18',
          'dateBasis': 'explicit',
          'dependsOn': <String>[],
          'epic': 'Launch readiness',
          'sourceRef': {
            'startMs': 45000,
            'endMs': 58000,
            'quote':
                'Priya can you take the migration, it has to be done by the '
                    'eighteenth',
          },
        },
      ],
      'risks': [],
      'timelineAnchors': [
        {
          'label': 'Launch',
          'date': '2026-10-01',
          'sourceRef': {
            'startMs': 60000,
            'endMs': 66000,
            'quote': 'launch is the first of October',
          },
        },
      ],
    };

/// The transcript the fixture note cites. Every quote above appears here verbatim, so
/// quote verification passes — tests that want a fabricated item edit the note, not this.
const String fixtureTranscript = '''
[00:12] Priya: Okay, the big one this week is auth. we need to get off the legacy session
store before we hit any real traffic.
[00:30] Sam: Agreed. It cannot handle the load we are expecting, so we are retiring it
before launch, agreed?
[00:45] Sam: Priya can you take the migration, it has to be done by the eighteenth.
[00:58] Priya: Yes, two weeks is realistic.
[01:00] Sam: Good, because launch is the first of October and nothing moves that.
''';
