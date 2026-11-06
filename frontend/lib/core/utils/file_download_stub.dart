/// Non-web platforms: no direct download; callers fall back to copying the text.
bool downloadTextFile(String filename, String content, {String mime = 'text/csv'}) => false;
