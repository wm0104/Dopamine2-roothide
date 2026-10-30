#!/usr/bin/env python3
"""Ad-hoc sign the built app, then verify the exact repackaged delivery."""
import hashlib, json, pathlib, plistlib, shutil, subprocess, sys, tempfile, zipfile
ipa = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(__file__).resolve().parents[1]
def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT).decode()
magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
with tempfile.TemporaryDirectory() as temp:
    work = pathlib.Path(temp)
    with zipfile.ZipFile(ipa) as z:
        assert z.testzip() is None
        for entry in z.infolist():
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
    for p in sorted(app.rglob('*')):
        if not p.is_file() or p.is_symlink() or p == main: continue
        with p.open('rb') as f: header = f.read(4)
        if header not in magic: continue
        entitlements = run('ldid', '-e', str(p)).strip()
        args = ['codesign','--force','--sign','-','--timestamp=none']
        if entitlements:
            ent = work / 'nested.entitlements'
            ent.write_text(entitlements)
            plistlib.loads(ent.read_bytes())
            args += ['--entitlements', str(ent)]
        run(*args, str(p))
    for bundle in sorted(app.rglob('*.framework'), key=lambda p:len(p.parts), reverse=True):
        run('codesign','--force','--sign','-','--timestamp=none',str(bundle))
    run('codesign','--force','--sign','-','--timestamp=none','--entitlements',str(repo/'Application/Dopamine/Dopamine.entitlements'),str(app))
    print(run('codesign','--verify','--deep','--strict','--verbose=2',str(app)))
    ent = plistlib.loads(run('ldid','-e',str(main)).encode())
    assert ent.get('platform-application') is True and ent.get('com.apple.private.security.no-sandbox') is True
    assert info['CFBundleIdentifier'] == 'cn.zqbb.dopaRH'
    assert 'wm0104' in info['CFBundleShortVersionString']
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
    report = {'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundle':info['CFBundleIdentifier'],'architectures':arch,'sha256':digest,'bytes':ipa.stat().st_size,'commit':run('git','rev-parse','HEAD').strip(),'verification':['zip-crc','native-codesign-deep-strict','required-entitlements','bundled-manager','repacked-plist'],'device_tested':False}
    (ipa.parent/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
