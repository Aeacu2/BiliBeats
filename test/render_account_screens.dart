// Separate isolate: the render fixtures contain process-wide stores and
// asynchronous writes bound to each widget test's fake clock.
import 'render_screens.dart' as renders;

void main() => renders.main(accountOnly: true);
