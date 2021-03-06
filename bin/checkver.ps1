# checks websites for newer versions using an (optional) regular expression defined in the manifest
# use $dir to specify a manifest directory to check from, otherwise ./bucket is used
param(
    [String]$app,
    [String]$dir,
    [Switch]$update = $false,
    [Switch]$forceUpdate = $false
)

if (!$app -and $update) {
    # While developing the feature we only allow specific updates
    Write-Host "[ERROR] AUTOUPDATE CAN ONLY BE USED WITH A APP SPECIFIED" -f DarkRed
    exit
}

. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\manifest.ps1"
. "$psscriptroot\..\lib\config.ps1"
. "$psscriptroot\..\lib\buckets.ps1"
. "$psscriptroot\..\lib\autoupdate.ps1"
. "$psscriptroot\..\lib\json.ps1"
. "$psscriptroot\..\lib\versions.ps1"
. "$psscriptroot\..\lib\install.ps1" # needed for hash generation
. "$psscriptroot\..\lib\unix.ps1"

if(!$dir) { $dir = "$psscriptroot\..\bucket" }
$dir = resolve-path $dir

$search = "*"
if($app) { $search = $app }

# get apps to check
$queue = @()
gci $dir "$search.json" | % {
    $json = parse_json "$dir\$_"
    if($json.checkver) {
        $queue += ,@($_, $json)
    }
}

# clear any existing events
get-event | % {
    remove-event $_.sourceidentifier
}

$original = use_any_https_protocol

# start all downloads
$queue | % {
    $wc = new-object net.webclient
    $wc.Headers.Add("user-agent", "Scoop/1.0 (+http://scoop.sh/) (Windows NT 6.1; WOW64)")
    register-objectevent $wc downloadstringcompleted -ea stop | out-null

    $name, $json = $_

    $githubRegex = "\/releases\/tag\/(?:v)?([\d.]+)"

    $url = $json.homepage
    if($json.checkver.url) {
        $url = $json.checkver.url
    }
    $regex = ""
    $jsonpath = ""

    if ($json.checkver -eq "github") {
        if (!$json.homepage.StartsWith("https://github.com/")) {
            write-host "ERROR: $name checkver expects the homepage to be a github repository" -f DarkYellow
        }
        $url = $json.homepage + "/releases/latest"
        $regex = $githubRegex
    }

    if ($json.checkver.github) {
        $url = $json.checkver.github + "/releases/latest"
        $regex = $githubRegex
    }

    if($json.checkver.re) {
        $regex = $json.checkver.re
    }

    if($json.checkver.jp) {
        $jsonpath = $json.checkver.jp
    }

    if(!$jsonpath -and !$regex) {
        $regex = $json.checkver
    }

    $reverse = $json.checkver.reverse -and $json.checkver.reverse -eq "true"

    $state = new-object psobject @{
        app = (strip_ext $name);
        url = $url;
        regex = $regex;
        json = $json;
        jsonpath = $jsonpath;
        reverse = $reverse;
    }

    $wc.headers.add('Referer', (strip_filename $url))
    $wc.downloadstringasync($url, $state)
}

# wait for all to complete
$in_progress = $queue.length
while($in_progress -gt 0) {
    $ev = wait-event
    remove-event $ev.sourceidentifier
    $in_progress--

    $state = $ev.sourceeventargs.userstate
    $app = $state.app
    $json = $state.json
    $url = $state.url
    $expected_ver = $json.version
    $regexp = $state.regex
    $jsonpath = $state.jsonpath
    $reverse = $state.reverse
    $ver = ""

    $err = $ev.sourceeventargs.error
    $page = $ev.sourceeventargs.result

    write-host "$app`: " -nonewline

    if($err) {
        write-host -f darkred $err.message
        write-host -f darkred "URL $url is not valid"
        continue
    }

    if($jsonpath -and $regexp) {
        write-host -f darkred "'jp' and 're' shouldn't be used together"
        continue
    }

    if($jsonpath) {
        $ver = json_path $page $jsonpath
        if(!$ver) {
            $ver = json_path_legacy $page $jsonpath
        }
        if(!$ver) {
            write-host -f darkred "couldn't find '$jsonpath' in $url"
            continue
        }
    }

    if($regexp) {
        if($reverse) {
            $match = [regex]::matches($page, $regexp) | select-object -last 1
        } else {
            $match = [regex]::matches($page, $regexp) | select-object -first 1
        }

        if($match -and $match.Success) {
            $matchesHashtable = @{}
            $match.Groups | % { $matchesHashtable.Add($_.Name, $_.Value) }
            $ver = $matchesHashtable['1']
            if(!$ver) {
                $ver = $matchesHashtable['version']
            }
        } else {
            write-host -f darkred "couldn't match '$regexp' in $url"
            continue
        }
    }

    if(!$ver) {
        write-host -f darkred "couldn't find new version in $url"
        continue
    }

    if($ver -eq $expected_ver -and $forceUpdate -eq $false) {
        # version hasn't changed (step over if forced update)
        write-host "$ver" -f darkgreen
        continue
    }

    write-host "$ver" -f darkred -nonewline
    write-host " (scoop version is $expected_ver)" -NoNewline
    $update_available = (compare_versions $expected_ver $ver) -eq -1

    if ($json.autoupdate -and $update_available) {
        Write-Host " autoupdate available" -f Cyan
    } else {
        Write-Host ""
    }

    if($forceUpdate) {
        # forcing an update implies updating, right?
        $update = $true
    }

    if($update -and $json.autoupdate) {
        if($forceUpdate) {
            Write-Host "Forcing autoupdate!" -f DarkMagenta
        }
        try {
            autoupdate $app $dir $json $ver $matchesHashtable
        } catch {
            error $_.exception.message
        }
    }
}

set_https_protocols $original

<#
write-host "checking $(strip_ext (fname $_))..." -nonewline
$expected_ver = $json.version

$url = $json.checkver.url
if(!$url) { $url = $json.homepage }

$regexp = $json.checkver.re
if(!$regexp) { $regexp = $json.checkver }

$page = $wc.downloadstring($url)

if($page -match $regexp) {
    $ver = $matches[1]
    if($ver -eq $expected_ver) {
        write-host "$ver" -f darkgreen
    } else {
        write-host "$ver" -f darkred -nonewline
        write-host " (scoop version is $expected_ver)"
    }

} else {
    write-host "couldn't match '$regexp' in $url" -f darkred
}
#>
