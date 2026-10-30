#import "DOSourceMigration.h"
#import <sys/stat.h>
#import <unistd.h>
#import <dirent.h>
#import "DOBackupFileIO.h"

static NSString *const DOOwnedSource = @"https://wm0104.github.io/repo/";
static NSError *DOSE(NSString *message) {
    return [NSError errorWithDomain:@"DOSourceMigration" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSArray<NSString *> *DOWords(NSString *value) {
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *word in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (word.length) [words addObject:word];
    return words;
}
static BOOL DOOldURI(NSString *uri) {
    return [[NSURLComponents componentsWithString:uri].host.lowercaseString isEqualToString:@"apt.002599.xyz"];
}
static BOOL DOValidURI(NSString *uri) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:uri];
    return parts.host.length && !parts.user.length && !parts.password.length &&
        [@[@"http", @"https"] containsObject:parts.scheme.lowercaseString];
}
static NSString *DONormalized(NSString *text) {
    return [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

@implementation DOSourceMigration
+ (NSString *)sanitizedSourceText:(NSString *)text deb822:(BOOL)deb822 error:(NSError **)error {
    if (text.length > 1024 * 1024 || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound) {
        if (error) *error = DOSE(@"Source configuration is too large or contains NUL bytes.");
        return nil;
    }
    text = DONormalized(text);
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    if (!deb822) {
        NSRegularExpression *rule = [NSRegularExpression regularExpressionWithPattern:@"^\\s*deb(?:-src)?\\s+(?:\\[[^\\]\\r\\n]*\\]\\s+)?(\\S+)\\s+(\\S+)(?:\\s.*)?$" options:NSRegularExpressionCaseInsensitive error:nil];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!trim.length || [trim hasPrefix:@"#"]) { [result addObject:line]; continue; }
            NSTextCheckingResult *match = [rule firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
            if (!match) { if (error) *error = DOSE(@"Invalid one-line APT source. No files were changed."); return nil; }
            NSString *uri = [line substringWithRange:[match rangeAtIndex:1]];
            if (!DOValidURI(uri)) { if (error) *error = DOSE(@"Only HTTP(S) APT source URLs are supported."); return nil; }
            if (!DOOldURI(uri)) [result addObject:line];
        }
    } else {
        NSMutableArray<NSArray<NSString *> *> *paragraphs = [NSMutableArray array];
        NSMutableArray *current = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if (![line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) {
                if (current.count) { [paragraphs addObject:[current copy]]; [current removeAllObjects]; }
            } else [current addObject:line];
        }
        if (current.count) [paragraphs addObject:current];
        for (NSArray<NSString *> *paragraph in paragraphs) {
            NSMutableDictionary<NSString *,NSString *> *fields = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString *,NSMutableIndexSet *> *indices = [NSMutableDictionary dictionary];
            NSString *key = nil;
            for (NSUInteger i=0; i<paragraph.count; i++) {
                NSString *line = paragraph[i];
                if ([[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] hasPrefix:@"#"]) continue;
                if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) {
                    if (!key) { if (error) *error = DOSE(@"Invalid continued source field."); return nil; }
                    fields[key] = [fields[key] stringByAppendingFormat:@" %@", line];
                    [indices[key] addIndex:i];
                    continue;
                }
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location == NSNotFound || !colon.location) { if (error) *error = DOSE(@"Invalid deb822 source field."); return nil; }
                key = [[line substringToIndex:colon.location] lowercaseString];
                if (fields[key]) { if (error) *error = DOSE(@"Duplicate deb822 source field."); return nil; }
                fields[key] = [[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                indices[key] = [NSMutableIndexSet indexSetWithIndex:i];
            }
            if (!fields.count) { [result addObject:[paragraph componentsJoinedByString:@"\n"]]; continue; }
            if (!fields[@"types"].length || !fields[@"uris"].length || !fields[@"suites"].length) {
                if (error) *error = DOSE(@"APT sources must contain Types, URIs and Suites."); return nil;
            }
            for (NSString *type in DOWords(fields[@"types"])) {
                if (![@[@"deb",@"deb-src"] containsObject:type]) { if (error) *error = DOSE(@"Unsupported APT source type."); return nil; }
            }
            NSMutableArray *uris = [NSMutableArray array];
            BOOL changed = NO;
            for (NSString *uri in DOWords(fields[@"uris"])) {
                if (!DOValidURI(uri)) { if (error) *error = DOSE(@"Only HTTP(S) APT source URLs are supported."); return nil; }
                if (DOOldURI(uri)) changed = YES;
                else [uris addObject:uri];
            }
            if (!uris.count) continue;
            if (!changed) { [result addObject:[paragraph componentsJoinedByString:@"\n"]]; continue; }
            NSMutableArray *lines = [NSMutableArray array];
            for (NSUInteger i=0; i<paragraph.count; i++) {
                if (i == indices[@"uris"].firstIndex) [lines addObject:[@"URIs: " stringByAppendingString:[uris componentsJoinedByString:@" "]]];
                else if (![indices[@"uris"] containsIndex:i]) [lines addObject:paragraph[i]];
            }
            [result addObject:[lines componentsJoinedByString:@"\n"]];
        }
    }
    NSString *joined = [result componentsJoinedByString:deb822 ? @"\n\n" : @"\n"];
    return joined.length && ![joined hasSuffix:@"\n"] ? [joined stringByAppendingString:@"\n"] : joined;
}

static BOOL DOHasOwnedURI(NSString *text) {
    for (NSString *token in DOWords(text)) {
        NSURLComponents *uri = [NSURLComponents componentsWithString:token];
        NSString *path = [uri.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if ([uri.host.lowercaseString isEqualToString:@"wm0104.github.io"] && [path isEqualToString:@"repo"] &&
            [uri.scheme.lowercaseString isEqualToString:@"https"]) return YES;
    }
    return NO;
}
+ (BOOL)migrateSourcesAtRoot:(NSString *)root error:(NSError **)error {
    if (!root.length || ![root hasPrefix:@"/"] || [root isEqual:@"/"]) return BFail(error, @"No active RootHide environment");
    // Resolve only fixed runtime anchors (RootHide's var link is intentional).
    NSString *library = BCanonical([root stringByAppendingPathComponent:@"var/mobile/Library"]);
    NSString *apt = BCanonical([root stringByAppendingPathComponent:@"etc/apt"]);
    int lfd = BOpenDirectory(library), afd = BOpenDirectory(apt), cfd = -1;
    if (lfd < 0 || afd < 0) { if (lfd >= 0) close(lfd); if (afd >= 0) close(afd); return BFail(error, @"Runtime source anchors unavailable"); }
    @try {
        NSMutableArray *created = [NSMutableArray array];
        cfd = BParent(lfd, @"RootHide/.marker", YES, 501, 501, created);
        if (cfd < 0) return BFail(error, @"Unsafe RootHide directory");
        BOOL missing = NO;
        NSData *marker = BRead(cfd, @".wm0104-source-migration-v1", NULL, &missing, error);
        if (marker) return YES;
        if (!missing) return NO;
        NSMutableArray *paths = [NSMutableArray arrayWithObject:@"apt/sources.list"];
        int dfd = BParent(afd, @"sources.list.d/.entry", NO, 0, 0, nil);
        if (dfd < 0) return BFail(error, @"APT sources directory unavailable");
        DIR *dir = fdopendir(dfd);
        if (!dir) { close(dfd); return BFail(error, @"Cannot enumerate sources"); }
        struct dirent *entry; BOOL valid = YES; NSUInteger count = 0;
        while ((entry = readdir(dir))) {
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            if ([name isEqual:@"."] || [name isEqual:@".."]) continue;
            if (!name || !BPath(name) || ++count > 500) { valid = NO; break; }
            if ([@[@"list", @"sources"] containsObject:name.pathExtension]) [paths addObject:[@"apt/sources.list.d" stringByAppendingPathComponent:name]];
        }
        closedir(dir); if (!valid) return BFail(error, @"Invalid source directory entries");
        [paths addObject:@"library/Application Support/xyz.willy.Zebra/sources.list"];
        NSMutableDictionary *before = [NSMutableDictionary dictionary], *after = [NSMutableDictionary dictionary], *metadata = [NSMutableDictionary dictionary];
        BOOL ownsAPT = NO;
        for (NSString *key in paths) {
            BOOL isAPT = [key hasPrefix:@"apt/"]; int fd = isAPT ? afd : lfd;
            NSString *relative = [key substringFromIndex:isAPT ? 4 : 8]; struct stat st;
            NSData *data = BRead(fd, relative, &st, &missing, error);
            if (!data) { if (missing) continue; return NO; }
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *clean = text ? [self sanitizedSourceText:text deb822:[key.pathExtension isEqual:@"sources"] error:error] : nil;
            if (!clean) return BFail(error, @"Invalid source text; no sources changed");
            if (isAPT) ownsAPT |= DOHasOwnedURI(clean);
            else if (!DOHasOwnedURI(clean)) clean = [clean stringByAppendingFormat:@"\ndeb %@ ./\n", DOOwnedSource];
            if (![text isEqual:clean]) {
                before[key] = data; after[key] = [clean dataUsingEncoding:NSUTF8StringEncoding];
                metadata[key] = [NSData dataWithBytes:&st length:sizeof(st)];
            }
        }
        if (!ownsAPT) {
            NSString *key = @"apt/sources.list.d/wm0104-custom.sources";
            NSData *old = BRead(afd, @"sources.list.d/wm0104-custom.sources", NULL, &missing, error);
            if (old || !missing) return BFail(error, @"wm0104-custom.sources exists; rename it before migration");
            after[key] = [[NSString stringWithFormat:@"Types: deb\nURIs: %@\nSuites: ./\nComponents:\n", DOOwnedSource] dataUsingEncoding:NSUTF8StringEncoding];
        }
        struct stat mode = {0}; mode.st_mode = 0600; mode.st_uid = getuid(); mode.st_gid = getgid();
        NSData *saved = BRead(cfd, @".wm0104-sources-before-v1.plist", NULL, &missing, error);
        if (!saved && !missing) return NO;
        if (!saved) {
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:before format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
            if (!data || !BWrite(cfd, @".wm0104-sources-before-v1.plist", data, mode, -1, nil, error)) return NO;
        }
        // Pinned directory descriptors are used for preflight, writes AND rollback.
        for (NSString *key in after) {
            BOOL isAPT = [key hasPrefix:@"apt/"];
            NSData *now = BRead(isAPT ? afd : lfd, [key substringFromIndex:isAPT ? 4 : 8], NULL, &missing, error);
            if ((before[key] && ![now isEqual:before[key]]) || (!before[key] && !missing)) return BFail(error, @"Source changed during migration; no writes applied");
        }
        NSMutableArray *written = [NSMutableArray array]; NSError *failure = nil;
        for (NSString *key in [after.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            struct stat st = {0}; st.st_mode = 0644; st.st_uid = getuid(); st.st_gid = getgid();
            if (metadata[key]) [metadata[key] getBytes:&st length:sizeof(st)];
            BOOL isAPT = [key hasPrefix:@"apt/"]; [written addObject:key];
            if (!BWrite(isAPT ? afd : lfd, [key substringFromIndex:isAPT ? 4 : 8], after[key], st, -1, nil, &failure)) break;
        }
        if (!failure && !BWrite(cfd, @".wm0104-source-migration-v1", [@"1\n" dataUsingEncoding:NSUTF8StringEncoding], mode, -1, nil, &failure)) {}
        if (!failure) return YES;
        BOOL rollback = YES;
        for (NSString *key in written.reverseObjectEnumerator) {
            BOOL isAPT = [key hasPrefix:@"apt/"]; int fd = isAPT ? afd : lfd; NSString *relative = [key substringFromIndex:isAPT ? 4 : 8];
            if (before[key]) {
                struct stat st; [metadata[key] getBytes:&st length:sizeof(st)];
                if (!BWrite(fd, relative, before[key], st, -1, nil, nil)) rollback = NO;
            } else {
                int p = BParent(fd, relative, NO, 0, 0, nil);
                if (p < 0) rollback = NO;
                else { if (unlinkat(p, relative.lastPathComponent.fileSystemRepresentation, 0) && errno != ENOENT) rollback = NO; close(p); }
            }
        }
        unlinkat(cfd, ".wm0104-source-migration-v1", 0);
        return BFail(error, [NSString stringWithFormat:@"%@. %@; snapshot: RootHide/.wm0104-sources-before-v1.plist", failure.localizedDescription, rollback ? @"Sources rolled back" : @"Rollback incomplete"]);
    } @finally { if (cfd >= 0) close(cfd); close(lfd); close(afd); }
}
@end
