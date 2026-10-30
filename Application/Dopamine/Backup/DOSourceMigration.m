#import "DOSourceMigration.h"
#import <sys/stat.h>
#import <unistd.h>

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

static NSData *DOReadSource(NSString *path, NSError **error) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size > 1024*1024) {
        if (error) *error = DOSE([NSString stringWithFormat:@"Unsafe or unreadable source file: %@", path.lastPathComponent]);
        return nil;
    }
    return [NSData dataWithContentsOfFile:path options:0 error:error];
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
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!root.length || ![root hasPrefix:@"/"] || [root isEqualToString:@"/"]) {
        if (error) *error = DOSE(@"No active RootHide environment."); return NO;
    }
    NSString *config = [root stringByAppendingPathComponent:@"var/mobile/Library/RootHide"];
    NSString *marker = [config stringByAppendingPathComponent:@".wm0104-source-migration-v1"];
    struct stat markerStat;
    if (lstat(marker.fileSystemRepresentation, &markerStat) == 0) {
        if (!S_ISREG(markerStat.st_mode) || markerStat.st_nlink != 1) { if (error) *error = DOSE(@"Unsafe migration marker."); return NO; }
        return YES;
    }
    NSString *apt = [root stringByAppendingPathComponent:@"etc/apt/sources.list.d"];
    struct stat aptStat;
    if (lstat(apt.fileSystemRepresentation, &aptStat) || !S_ISDIR(aptStat.st_mode)) {
        if (error) *error = DOSE(@"APT source directory is unavailable."); return NO;
    }
    NSArray *names = [fm contentsOfDirectoryAtPath:apt error:error];
    if (!names || names.count > 500) { if (error && !*error) *error = DOSE(@"Too many source files."); return NO; }
    NSMutableDictionary<NSString *,NSData *> *before = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *,NSData *> *after = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *,NSDictionary *> *attributes = [NSMutableDictionary dictionary];
    BOOL ownsAPT = NO;
    for (NSString *name in names) {
        if (![@[@"list",@"sources"] containsObject:name.pathExtension.lowercaseString]) continue;
        NSString *path = [apt stringByAppendingPathComponent:name];
        NSData *data = DOReadSource(path,error);
        if (!data) return NO;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) { if (error) *error = DOSE(@"Source configuration is not UTF-8."); return NO; }
        NSString *clean = [self sanitizedSourceText:text deb822:[name.pathExtension.lowercaseString isEqualToString:@"sources"] error:error];
        if (!clean) return NO;
        ownsAPT |= DOHasOwnedURI(clean);
        if (![clean isEqualToString:text]) {
            before[path] = data; after[path] = [clean dataUsingEncoding:NSUTF8StringEncoding];
            attributes[path] = [fm attributesOfItemAtPath:path error:error];
            if (!attributes[path]) return NO;
        }
    }
    if (!ownsAPT) {
        NSString *path = [apt stringByAppendingPathComponent:@"wm0104-custom.sources"];
        if ([fm fileExistsAtPath:path]) { if (error) *error = DOSE(@"wm0104-custom.sources already exists with different contents; please rename it first."); return NO; }
        after[path] = [[NSString stringWithFormat:@"Types: deb\nURIs: %@\nSuites: ./\nComponents:\n",DOOwnedSource] dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSString *zebra = [root stringByAppendingPathComponent:@"var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list"];
    struct stat zebraStat;
    if (lstat(zebra.fileSystemRepresentation, &zebraStat) == 0) {
        NSData *data = DOReadSource(zebra,error);
        if (!data) return NO;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *clean = text ? [self sanitizedSourceText:text deb822:NO error:error] : nil;
        if (!clean) { if (error && !*error) *error = DOSE(@"Zebra sources are not valid UTF-8."); return NO; }
        if (!DOHasOwnedURI(clean)) clean = [clean stringByAppendingFormat:@"\ndeb %@ ./\n",DOOwnedSource];
        if (![clean isEqualToString:text]) {
            before[zebra] = data; after[zebra] = [clean dataUsingEncoding:NSUTF8StringEncoding];
            attributes[zebra] = [fm attributesOfItemAtPath:zebra error:error];
            if (!attributes[zebra]) return NO;
        }
    }
    // Preflight is complete. Keep an exact rollback snapshot before touching sources.
    if (![fm createDirectoryAtPath:config withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
    NSString *snapshot = [config stringByAppendingPathComponent:@".wm0104-sources-before-v1.plist"];
    if (![fm fileExistsAtPath:snapshot]) {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:before format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!data || ![data writeToFile:snapshot options:NSDataWritingAtomic error:error]) return NO;
        if (![fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:snapshot error:error]) return NO;
    }
    NSMutableArray *written = [NSMutableArray array];
    NSError *failure = nil;
    for (NSString *path in [[after allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [written addObject:path];
        if (![after[path] writeToFile:path options:NSDataWritingAtomic error:&failure]) break;
        NSDictionary *old = attributes[path];
        NSDictionary *mode = old ? @{NSFilePosixPermissions:old[NSFilePosixPermissions],NSFileOwnerAccountID:old[NSFileOwnerAccountID],NSFileGroupOwnerAccountID:old[NSFileGroupOwnerAccountID]} : @{NSFilePosixPermissions:@0644,NSFileOwnerAccountID:@0,NSFileGroupOwnerAccountID:@0};
        if (![fm setAttributes:mode ofItemAtPath:path error:&failure]) break;
    }
    if (!failure && ![@"1\n" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:&failure]) {}
    if (!failure) return YES;
    NSMutableArray *rollbackFailures = [NSMutableArray array];
    for (NSString *path in written.reverseObjectEnumerator) {
        NSError *rollbackError = nil;
        if (before[path]) {
            if (![before[path] writeToFile:path options:NSDataWritingAtomic error:&rollbackError] ||
                ![fm setAttributes:@{NSFilePosixPermissions:attributes[path][NSFilePosixPermissions],NSFileOwnerAccountID:attributes[path][NSFileOwnerAccountID],NSFileGroupOwnerAccountID:attributes[path][NSFileGroupOwnerAccountID]} ofItemAtPath:path error:&rollbackError])
                [rollbackFailures addObject:path.lastPathComponent];
        } else if ([fm fileExistsAtPath:path] && ![fm removeItemAtPath:path error:&rollbackError]) [rollbackFailures addObject:path.lastPathComponent];
    }
    if (error) *error = rollbackFailures.count ? DOSE([NSString stringWithFormat:@"%@ Rollback failed for %@. Safety snapshot: %@", failure.localizedDescription,[rollbackFailures componentsJoinedByString:@", "],snapshot]) : failure;
    return NO;
}
@end
