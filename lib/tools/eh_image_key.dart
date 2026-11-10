/// Cache key for one e-hentai page image.
///
/// [page] is 1-based: it is the number used by a reader link and the value
/// [ImageManager.getEhImageNew] expects. The reader keeps its page list
/// 0-based, so it has to add one before asking for a key.
///
/// The two sides used to disagree by exactly one. Page N asked the disk cache
/// for page N-1's key, found page N-1's file and displayed it, so every page
/// showed the picture before it and never downloaded its own copy.
String ehPageCacheKey(String galleryLink, int page) => '$galleryLink$page';
