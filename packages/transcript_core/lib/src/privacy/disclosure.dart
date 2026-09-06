/// One statement of what the app does with each kind of data, used everywhere the
/// question gets asked.
///
/// The same facts have to be told in at least four places — onboarding, the in-app
/// privacy screen, App Store Connect's privacy questions, and the Play Console's Data
/// safety form — and they are answered months apart by whoever is doing the release.
/// That is exactly how an app ends up with a store listing that no longer matches what
/// it does. Everything derives from this list instead, and `tool/export_privacy.dart`
/// regenerates the doc the store answers are copied from, with CI failing if it drifts.
library;

/// Where a kind of data can end up.
enum DataDestination {
  /// Never leaves the device under any configuration.
  device('Stays on this device'),

  /// Reaches a machine on the user's own network, and no further.
  ownNetwork("Can reach a computer on the user's own network"),

  /// Reaches a third-party AI service, and only the one the user selected and keyed.
  chosenProvider('Can be sent to the AI service the user chose'),

  /// Would reach servers operated by the app's publisher. Nothing is in this state, and
  /// the enum entry exists so [PrivacyDisclosure.collectsNothing] can assert that.
  publisher('Sent to the app publisher');

  const DataDestination(this.label);
  final String label;
}

/// What the app does with one kind of data.
class DataPractice {
  const DataPractice({
    required this.id,
    required this.label,
    required this.destination,
    required this.storedOnDevice,
    required this.plainLanguage,
    this.userControls,
  });

  /// Stable identifier, so the generated doc has stable anchors.
  final String id;

  /// Short name, as it appears in a list.
  final String label;

  final DataDestination destination;

  /// Whether a copy is kept on the device after the operation finishes.
  final bool storedOnDevice;

  /// One or two sentences a person can actually read. Shown in the app.
  final String plainLanguage;

  /// What the user can do about it, when there is something. Null when the answer is
  /// "nothing to control, because it never goes anywhere".
  final String? userControls;

  /// True when this practice depends on which providers are configured, rather than
  /// being fixed. Those are the rows where the honest answer is "it depends, and here
  /// is what it depends on".
  bool get isConfigurationDependent =>
      destination == DataDestination.chosenProvider ||
      destination == DataDestination.ownNetwork;
}

/// Every practice, and the claims derived from them.
class PrivacyDisclosure {
  const PrivacyDisclosure._();

  static const List<DataPractice> practices = [
    DataPractice(
      id: 'audio',
      label: 'Audio recordings',
      destination: DataDestination.chosenProvider,
      storedOnDevice: true,
      plainLanguage:
          'Recordings are saved on this device. If you pick a cloud service for '
          'speech-to-text, the audio is uploaded to that service — directly from '
          'this device, using your own account — so it can be transcribed. Pick '
          'on-device recognition or a downloaded Whisper model and the audio never '
          'leaves the phone.',
      userControls:
          'Choose the transcription provider in Settings; delete a recording at any '
          'time from the library.',
    ),
    DataPractice(
      id: 'transcripts',
      label: 'Transcripts',
      destination: DataDestination.chosenProvider,
      storedOnDevice: true,
      plainLanguage:
          'The text of what was said is stored on this device. If you pick a cloud '
          'service to turn it into notes, the text is sent to that service. A model '
          'running on your own computer keeps it on your network instead.',
      userControls: 'Choose the notes provider in Settings.',
    ),
    DataPractice(
      id: 'notes',
      label: 'Notes, tasks and boards',
      destination: DataDestination.device,
      storedOnDevice: true,
      plainLanguage:
          'Everything the app produces — summaries, action items, the board and the '
          'timeline — is stored on this device only. Exports go wherever you send '
          'them, which is up to you.',
      userControls: 'Export or delete anything, at any time.',
    ),
    DataPractice(
      id: 'api-keys',
      label: 'API keys',
      destination: DataDestination.device,
      storedOnDevice: true,
      plainLanguage:
          'Keys are held in the system keychain (iOS) or the encrypted Keystore '
          '(Android). They are sent only to the service they belong to, as part of '
          'a request you triggered. They are never written to logs, diagnostics or '
          'exports.',
      userControls: 'Remove a saved key in Settings.',
    ),
    DataPractice(
      id: 'diagnostics',
      label: 'Crash diagnostics',
      destination: DataDestination.device,
      storedOnDevice: true,
      plainLanguage:
          'If the app crashes, it writes a report to a file on this device. The '
          'report holds the error, the stack trace and recent app events, with keys '
          'and personal paths stripped out. It contains no recording or transcript '
          'text, and it is not uploaded — you decide whether to send it.',
      userControls: 'View, share or delete crash reports in Settings.',
    ),
    DataPractice(
      id: 'accounts',
      label: 'Accounts and identifiers',
      destination: DataDestination.device,
      storedOnDevice: false,
      plainLanguage:
          'There is no account to create and no sign-in. The app assigns no user or '
          'advertising identifier and contains no analytics or advertising SDK.',
    ),
  ];

  static DataPractice byId(String id) =>
      practices.firstWhere((p) => p.id == id);

  /// The claim the store listing makes, asserted rather than assumed: no practice may
  /// send anything to servers the publisher runs, because the publisher runs none.
  ///
  /// A test pins this. If someone later adds an analytics SDK or a hosted sync feature,
  /// the honest thing is for that test to fail loudly and the store answers to change
  /// with it — not for this claim to quietly become false.
  static bool get collectsNothing =>
      practices.every((p) => p.destination != DataDestination.publisher);

  /// The rows whose answer depends on how the user configured their providers. These
  /// are the ones onboarding has to explain, because they are the ones where the user's
  /// choice is the privacy control.
  static List<DataPractice> get configurationDependent =>
      practices.where((p) => p.isConfigurationDependent).toList();

  /// What goes in App Store Connect's "Data Collection" question.
  ///
  /// Apple's definition of "collect" is transmission off the device to the developer or
  /// a third party *acting on the developer's behalf*. A key the user supplies, sent by
  /// the user's own device to the user's own account with a provider they chose, is not
  /// collection by the developer — but the reasoning has to be written down, because it
  /// is the question App Review will ask.
  static const String appStoreDataCollectionAnswer =
      'No data collected. The app has no backend, no account system, no analytics and '
      'no advertising SDK. Recordings and transcripts are sent only to the AI provider '
      'the user selects, using the user\'s own API key, directly from the device — a '
      'user-directed transfer to a service the user has their own relationship with, '
      'not collection by this app or on its behalf.';

  /// What goes in the Play Console's Data safety form.
  static const String playDataSafetyAnswer =
      'No data collected and no data shared with the developer. Audio and transcripts '
      'may be transmitted to a third-party AI service, but only the one the user '
      'configures with their own credentials, and only to perform the transcription or '
      'summarisation the user requested. All app-generated content stays in app-private '
      'storage. Data is encrypted in transit (HTTPS); plain HTTP is permitted only for '
      'servers on the user\'s own local network.';
}
