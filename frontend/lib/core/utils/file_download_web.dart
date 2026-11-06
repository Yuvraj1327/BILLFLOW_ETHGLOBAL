import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Flutter Web: triggers a browser download of [content].
bool downloadTextFile(String filename, String content, {String mime = 'text/csv'}) {
  try {
    final doc = globalContext['document'] as JSObject;
    final a = doc.callMethod('createElement'.toJS, 'a'.toJS) as JSObject;
    a['href'] = 'data:$mime;charset=utf-8,${Uri.encodeComponent(content)}'.toJS;
    a['download'] = filename.toJS;
    a.callMethod('click'.toJS);
    return true;
  } catch (_) {
    return false;
  }
}
