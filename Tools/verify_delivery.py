#!/usr/bin/env python3
"""Ad-hoc sign the built app, then verify the exact repackaged delivery."""
import hashlib, json, pathlib, plistlib, shutil, subprocess, sys, tempfile, zipfile
ipa = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(__file__).resolve().parents[1]
def run(*args):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT).decode()
    except subprocess.CalledProcessError as error:
        print(error.output.decode(errors='replace'), file=sys.stderr)
        raise

def read_entitlements(path):
    result = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(path)], capture_output=True)
    if result.returncode:
        if b'code object is not signed at all' in result.stderr:
            return {}
        raise RuntimeError(result.stderr.decode(errors='replace'))
    data = result.stdout.strip()
    value = plistlib.loads(data) if data else {}
    assert isinstance(value, dict), 'Entitlements must be a dictionary'
    return value
magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
with tempfile.TemporaryDirectory() as temp:
    work = pathlib.Path(temp)
    with zipfile.ZipFile(ipa) as z:
        assert z.testzip() is None
        for entry in z.infolist():
            assert (entry.external_attr >> 16) & 0o170000 != 0o120000, 'Symlink ZIP entries require explicit preservation; refusing unsafe repack'
            assert not pathlib.PurePosixPath(entry.filename).is_absolute() and '..' not in pathlib.PurePosixPath(entry.filename).parts
        z.extractall(work)
        # zipfile does not preserve executable bits by default.
        for entry in z.infolist():
            mode = entry.external_attr >> 16
            if mode and not entry.is_dir(): (work / entry.filename).chmod(mode & 0o777)
    apps = list((work / 'Payload').glob('*.app'))
    assert len(apps) == 1
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    main = app / info['CFBundleExecutable']
    nested_entitlements = {}
    for p in sorted(app.rglob('*')):
        if not p.is_file() or p.is_symlink() or p == main: continue
        with p.open('rb') as f: header = f.read(4)
        if header not in magic: continue
        entitlements = read_entitlements(p)
        nested_entitlements[p] = entitlements
        args = ['codesign','--force','--sign','-','--timestamp=none']
        if entitlements:
            ent = work / 'nested.entitlements'
            ent.write_bytes(plistlib.dumps(entitlements))
            args += ['--entitlements', str(ent)]
        run(*args, str(p))
    for bundle in sorted(app.rglob('*.framework'), key=lambda p:len(p.parts), reverse=True):
        framework_info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        minimum = lambda value: tuple((list(map(int, value.split('.'))) + [0, 0, 0])[:3])
        assert minimum(framework_info['MinimumOSVersion']) <= minimum(info['MinimumOSVersion']), f'Framework deployment target exceeds app: {bundle}'
        run('codesign','--force','--sign','-','--timestamp=none','--preserve-metadata=entitlements',str(bundle))
    run('codesign','--force','--sign','-','--timestamp=none','--entitlements',str(repo/'Application/Dopamine/Dopamine.entitlements'),str(app))
    print(run('codesign','--verify','--deep','--strict','--verbose=2',str(app)))
    for path, expected in nested_entitlements.items():
        assert read_entitlements(path) == expected, f'Nested entitlements changed: {path}'
    ent = read_entitlements(main)
    assert ent.get('platform-application') is True and ent.get('com.apple.private.security.no-sandbox') is True
    assert info['CFBundleIdentifier'] == 'cn.zqbb.dopaRH'
    assert 'wm0104' in info['CFBundleShortVersionString']
    # The RootHide environment version must be explicit: a custom revision suffix
    # made the old last-'-' parsing report a permanent environment update.
    assert info['DORootHideVersion'] == (repo/'BaseBin/_external/basebin/.version-roothide').read_text().strip()
    assert (app/'roothideWhite.deb').is_file() and (app/'basebin.tar').is_file()
    assert not (app/'Frameworks/palera1n.framework').exists()
    assert not (app/'bootstrap_1800.tar.zst').exists()
    arch = run('lipo','-archs',str(main)).strip()
    assert 'arm64' in arch
    output = work/'delivery.ipa'
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
        for path in sorted((work/'Payload').rglob('*')):
            if path.is_file(): z.write(path,path.relative_to(work))
    shutil.copyfile(output,ipa)
    shutil.copyfile(ipa,ipa.with_suffix('.tipa'))
    with zipfile.ZipFile(ipa) as z:
        assert z.testzip() is None
        pl = plistlib.loads(z.read('Payload/'+app.name+'/Info.plist'))
        assert pl == info
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    ipa.with_name(ipa.name+'.sha256').write_text(digest+'  '+ipa.name+'\n')
    report = {'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundle':info['CFBundleIdentifier'],'architectures':arch,'sha256':digest,'bytes':ipa.stat().st_size,'commit':run('git','rev-parse','HEAD').strip(),'verification':['zip-crc','native-codesign-deep-strict','required-entitlements','bundled-manager','repacked-plist','nested-entitlements-preserved','framework-minimum-os'],'device_tested':False}
    (ipa.parent/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
