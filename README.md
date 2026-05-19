# BDLOGGING (Logging package)

A flutter logging package for dart and flutter.

Provide logging functionality with plug-ins log handlers.

## Getting started

BDLogging comes with four out-of-the-box log handlers.

* ConsoleLogHandler (Log events to the console)
* FileLogHandler (Log events to one or multiple files)
* IsolateFileLogHandler (Log events to files in a separate isolate)
* EncryptedIsolateFileLogHandler (Log events with sensitive data encryption)

You can create your own log handler that covers your needs by implementing BDLogHandler.

You can add as many log handler message with be dispatched to them if meeting the requirement.
## Usage

### Encrypted logs (QA-friendly)

BDLogging ships with `EncryptedIsolateFileLogHandler` to protect sensitive
substrings in log messages (passwords, tokens, emails, phone numbers) while
keeping the rest of the message readable. Only the sensitive part of the
message is encrypted; timestamps and other log fields remain unchanged.

### Security Warning

**Error objects are not encrypted.** When logging errors using the `error`, `debug`, `warning`, or `log` methods, any sensitive information contained in the error object or exception will be logged in plaintext. Avoid including sensitive data such as passwords, API keys, or personal information in error objects.

```dart
// ⚠️ WARNING: This will log sensitive data in plaintext
logger.error('Login failed', Exception('Invalid credentials: password=secret123'));

// ✅ RECOMMENDED: Sanitize error messages
logger.error('Login failed', Exception('Invalid credentials provided'));
```

### Multiple Handlers (Flutter)

In Flutter apps, **shared isolate mode is enabled by default** when using multiple
`IsolateFileLogHandler` instances. This automatically reduces memory overhead and
enables cross-isolate logging:

```dart
void main() {
  // Shared mode is enabled by default on Flutter - just create your handlers
  final handler1 = IsolateFileLogHandler(logDir, logNamePrefix: 'app');
  final handler2 = IsolateFileLogHandler(logDir, logNamePrefix: 'network');
  final encrypted = EncryptedIsolateFileLogHandler(logDir, encryptor: enc);

  BDLogger()
    ..addHandler(handler1)
    ..addHandler(handler2)
    ..addHandler(encrypted);

  runApp(MyApp());
}
```

**Benefits (automatic on Flutter):**
- **Memory efficient**: 1 shared isolate instead of N dedicated isolates (~2MB saved per handler)
- **Cross-isolate compatible**: OS-spawned isolates (push notifications, background tasks) automatically discover and use the shared logger
- **Zero configuration**: Works out of the box

**To disable shared mode** (e.g., for testing or specific use cases):
```dart
void main() {
  BDLogger.configureSharedIsolate(enabled: false);
  // Now each handler gets its own dedicated isolate
}
```

**Note**: Pure Dart CLI apps automatically use dedicated isolate mode (1:1 pattern) since `IsolateNameServer` is unavailable.

**Technical Note - Serialization for Hot Reload Safety**: Inter-isolate communication uses map-based message serialization rather than sending Dart objects directly. This is critical during development: when hot-reload occurs, class definitions in the main isolate change, but the worker isolate's class definitions may not. Sending Dart objects would cause type mismatches and message dispatch failures. By serializing to maps, messages remain compatible across hot-reloads since the protocol is data-driven rather than type-dependent. During runtime, maps are deserialized using fresh type definitions, ensuring stability even when class definitions change.

### Decrypting encrypted values

Each encryption algorithm has its own decryption tool and documentation:

| Algorithm | Encryptor Class | Decryption Guide |
|-----------|-----------------|------------------|
| AES-GCM | `AesGcmSensitiveDataEncryptor` | [scripts/aes-gcm/](scripts/aes-gcm/) |

**For QA/Support staff**: Each algorithm folder contains a browser-based decryption tool (`decrypt.html`) that requires no programming knowledge. Just open it in your browser, paste the encrypted value, and enter the password.

**For Developers**: Each algorithm folder contains code examples in Dart, Python, and JavaScript.

### Example usage in app

```dart
final handler = EncryptedIsolateFileLogHandler(
  Directory.current,
  encryptor: AesGcmSensitiveDataEncryptor('my-secret-password'),
  options: const EncryptedIsolateFileLogHandlerOptions(
    fileOptions: EncryptedLogFileOptions(
      logNamePrefix: 'secure',
    ),
  ),
);
```

###  Get an instance of BDLogger.

```dart
final BDLogger logger = BDLogger();
```

Note: BDLogger is a singleton so you can call it anywhere.

### Add your log handler.

```dart
logger.addHandler(new ConsoleLogHandler());
```

Note:
* You can add as many log handler as you want.
* You can specify the BDLevel of logging messages that your log handler support.

```dart
final BDLogger logger = BDLogger();

logger.addHandler(new ConsoleLogHandler());

logger.addHandler(
  new FileLogHandler(
    logNamePrefix: 'example',
    maxLogSizeInMb: 5,
    maxFilesCount: 5,
    logFileDirectory: Directory.current,
    supportedLevels: <BDLevel>[BDLevel.error],
  ),
);
```
### Logging messages

You can log messages and errors using the current available method.

```dart
final BDLogger logger = BDLogger();

logger.debug(params);
logger.info(params);
logger.warning(params);
logger.error(params);
logger.log(params);
```

### Formatting logging messages

BDLogging the interface LogFormatter can be implemented to define how you would wish logging messages to be formatted.

Note: a Default log formatter is provided.

## Development

### Running Tests

**Note**: This library is compatible with both Flutter and pure Dart applications. However, the test suite requires Flutter's runtime environment to run isolate-based integration tests.

Always use:

```bash
flutter test
```

**Do not use** `dart test` - while the library itself works in pure Dart environments, the test suite uses Flutter's `IsolateNameServer` and other Flutter-specific APIs for testing isolate handlers.

### Contributing

Before submitting changes:

1. Format code: `dart format .`
2. Check for issues: `flutter analyze`
3. Run tests with coverage: `flutter test --coverage`

See [AGENTS.md](AGENTS.md) for detailed development guidelines.
