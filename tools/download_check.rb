#!/usr/bin/env ruby

=begin
Checks a download page URL for compliance with ASF guidelines.


Note: the GUI interface is currently at www/members/download_check.cgi

=end

$LOAD_PATH.unshift '/srv/whimsy/lib'
require 'whimsy/asf'
require 'wunderbar'
require 'net/http'
require 'nokogiri'
require 'time'

=begin
Checks performed: (F=fatal, E=error, W=warn)
TBA
=end

$SAFE = 1

$CLI = false
$VERBOSE = false

$ARCHIVE_CHECK = false
$ALWAYS_CHECK_LINKS = false
$NO_CHECK_LINKS = false
$NOFOLLOW = false # may be reset
$ALLOW_HTTP = false # http links generate Warning, not Error

$VERSION = nil

# match an artifact
# TODO detect artifacts by URL as well if possible
ARTIFACT_RE = %r{/([^/]+\.(tar|tar\.gz|deb|nbm|zip|tgz|tar\.bz2|jar|war|msi|exe|rar|rpm|nar))(&action=download)?$}

def init
  # build a list of validation errors
  @tests = []
  @fails = 0
  if $NO_CHECK_LINKS
    $NOFOLLOW = true
    I "Will not check links"
  else
    if $ALWAYS_CHECK_LINKS
      I "Will check links even if download page has errors"
    else
      I "Will check links if download page has no errors"
    end      
  end
  I "Will %s archive.apache.org links in checks" % ($ARCHIVE_CHECK ? 'include' : 'not include')
end

# save the result of a test
def test(severity, txt)
  @tests << {severity => txt}
  @fails +=1 unless severity == :I or severity == :W
end

def F(txt)
  test(:F, txt)
end

def E(txt)
  test(:E, txt)
end

def W(txt)
  test(:W, txt)
end

def I(txt)
  test(:I, txt)
end

# extract test entries with key k
def tests(k)
  @tests.map{|t| t[k]}.compact
end

# extract test entries with key k
def testentries(k)
  @tests.select{|t| t[k]}.compact
end

def showList(list, header)
  unless list.empty?
    _h2_ header
    _ul do
      list.each { |item| _li item }
    end
  end
end

def displayHTML
  fatals = tests(:F)
  errors = tests(:E)
  warns = tests(:W)

  if !fatals.empty?
    _h2_.bg_danger "The page at #@url failed our checks:"
  elsif !errors.empty?
    _h2_.bg_warning "The page at #@url has some problems:"
  elsif !warns.empty?
    _h2_.bg_warning "The page at #@url has some minor issues"
  else
    _h2_.bg_success "The page at #@url looks OK, thanks for using this service"
  end

  if @fails > 0
    showList(fatals, "Fatal errors:")
    showList(errors, "Errors:")
  end

  showList(warns, "Warnings:")

  _h2_ 'Tests performed'
  _ol do
    @tests.each { |t| t.map{|k,v| _li "#{k}: - #{v}"}}
  end
  _h4_ 'F: fatal, E: Error, W: warning, I: info (success)'
end

# get an HTTP URL
def HEAD(url)
  puts ">> HEAD #{url}" if $VERBOSE
  url.untaint
  uri = URI.parse(url)
  unless uri.scheme
    W "No scheme for URL #{url}, assuming http"
    uri = URI.parse("http:"+url)
  end
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  request = Net::HTTP::Head.new(uri.request_uri)
  http.request(request)
end

# get an HTTP URL=> response
def GET(url)
  puts ">> GET #{url}" if $VERBOSE
  url.untaint
  uri = URI.parse(url).untaint
  unless uri.scheme
    W "No scheme for URL #{url}, assuming http"
    uri = URI.parse("http:"+url).untaint
  end
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  request = Net::HTTP::Get.new(uri.request_uri)
  http.request(request.untaint)
end

# Check page exists
def check_head(path, severity = :E, expectedStatus = "200", log=true, allowRedirect=false)
  response = HEAD(path)
  code = response.code ||  '?'
  if code == '403' # someone does not like Whimsy?
    W "HEAD #{path} - HTTP status: #{code} - retry"
    response = HEAD(path)
    code = response.code ||  '?'
  elsif allowRedirect and code == '302'
    location = response['location']
    if location.start_with? 'https://downloads.apache.org/'
      response = HEAD(location)
      code = response.code ||  '?'
    end
  end
  if code != expectedStatus
    test(severity, "HEAD #{path} - HTTP status: #{code} expected: #{expectedStatus}") unless severity == nil
    return nil
  end
  I "Checked HEAD #{path} - OK (#{code})" if log
  response
end

# check page can be read => body
def check_page(path, severity=:E, expectedStatus="200", log=true)
  response = GET(path)
  code = response.code ||  '?'
  if code != expectedStatus
    test(severity, "Fetched #{path} - HTTP status: #{code} expected: #{expectedStatus}") unless severity == nil
    return nil
  end
  I "Fetched #{path} - OK (#{code})" if log
  puts "Fetched #{path} - OK (#{code})" if $CLI
  if code == '200'
    return response.body
  else
    return response
  end
end

# Check closer/download page
def check_closer_down(url)
  # N.B. HEAD does not work; it returns success
  res = check_page(url, :E, "302", false)
  loc = res['location']
  res = check_head(loc, :E, "200", false)
  return unless res
  ct = res.content_type
  cl = res.content_length
  if ct and cl
    I "Checked #{url} OK - ct=#{ct} cl=#{cl}"
  elsif cl > 0
    W "Possible issue with #{url} ct=#{ct} cl=#{cl}"
  else
    E "Problem with #{url} ct=#{ct} cl=#{cl}"
  end
end

def WE(msg)
  if $ALLOW_HTTP
    W msg
  else
    E msg
  end
end
# returns www|archive, stem and the hash extension
def check_hash_loc(h,tlp)
  if h =~ %r{^(https?)://(?:(archive|www)\.)?apache\.org/dist/(?:incubator/)?#{tlp}/.*?([^/]+)\.(\w{3,6})$}
    WE "HTTPS! #{h}" unless $1 == 'https'
    return $2,$3,$4
  elsif h =~ %r{^(https?)://(downloads)\.apache\.org/(?:incubator/)?#{tlp}/.*?([^/]+)\.(\w{3,6})$}
    WE "HTTPS! #{h}" unless $1 == 'https'
    return $2,$3,$4
  elsif h =~ %r{^(https?)://repo\.(maven)\.apache\.org/maven2/org/apache/#{tlp}/.+/([^/]+)(\.(\w{3,6}))$} # Maven
    WE "HTTPS! #{h}" unless $1 == 'https'
    W "Unexpected hash location #{h} for #{tlp}"
    return $2,$3,$4
  else
    E "Unexpected hash location #{h} for #{tlp}"
    nil
  end
end

# get the https? links as Array of [href,text]
def get_links(body)
  doc = Nokogiri::HTML(body)
  nodeset = doc.css('a[href]')    # Get anchors w href attribute via css
  links = nodeset.map {|node|
    href = node.attribute("href").to_s
    text = node.text.gsub(/[[:space:]]+/,' ')
    [href,text]
  }.select{|x,y| x =~ %r{^(https?:)?//} }
end

VERIFY_TEXT = [
 'the integrity of the downloaded files',
 'verify the integrity', # commons has this as a link; perhaps try converting page to text only?
 'verify that checksums and signatures are correct',
 '#verifying-signature',
 'check that the download has completed OK',
 'You should verify your download',
 'downloads can be verified',
 'www.apache.org/info/verification.html',
 'verify your mirrored downloads',
 'verify your downloads',
 'verify the downloaded files',
 'All downloads should be verified',
 'verification instructions',
 ' encouraged to verify ',
 'To check a GPG signature',
]

ALIASES = {
    'sig' => 'asc',
    'pgp' => 'asc',
    'signature' => 'asc',
    'ascsignature' => 'asc',
    'pgpsignature' => 'asc',
    'pgpsignatures' => 'asc',
    'gpgsignature' => 'asc',
    'openpgpsignature' => 'asc',
}

# Need to be able to check if download is for a PMC or podling
# parameter is the website URL
# Also want to convert site to TLP
URL2TLP = Hash.new # URL host to TLP conversion
URL2TLP['jspwiki-wiki'] = 'jspwiki' # https://jspwiki-wiki.apache.org/Wiki.jsp?page=Downloads
PMCS = Set.new # is this a TLP?
ASF::Committee.pmcs.map do |p|
    site = p.site[%r{//(.+?)\.apache\.org},1]
    name = p.name
    URL2TLP[site] = name unless site == name
    PMCS << name
end

# Convert text reference to extension
# e.g. SHA256 => sha256; [SIG] => asc
def text2ext(txt)
    # need to strip twice to handle ' [ asc ] '
    # TODO: perhaps just remove all white-space?
    tmp = txt.downcase.strip.sub(%r{^\[(.+)\]$},'\1').sub('-','').sub(/ ?(digest|checksum)/,'').sub(/ \(tar\.gz\)| \(zip\)| /,'').strip
    ALIASES[tmp] || tmp
end

# Suite: perform all the HTTP checks
def checkDownloadPage(path, tlp, version)
    begin
        _checkDownloadPage(path.strip, tlp, version)
    rescue Exception => e
        F e
        if $CLI
          p e
          puts e.backtrace 
        end
    end
end

def _checkDownloadPage(path, tlp, version)
  isTLP = PMCS.include? tlp
  if version != ''
    I "Checking #{path} [#{tlp}] TLP #{isTLP} for version #{version} only ..."
  else
    I "Checking #{path} [#{tlp}] TLP #{isTLP} ..."
  end

  # check the main body
  if path.start_with? 'http'
    body = check_page(path)
  else
    file = path
    if file.start_with? '~'
      file = ENV['HOME'] + file[1..-1]
    end
    body = File.read(file.untaint)
  end
  
  return unless body

  hasDisclaimer = body.gsub(%r{\s+},' ').include? 'Incubation is required of all newly accepted'

  if isTLP
     W "#{tlp} has Incubator disclaimer" if hasDisclaimer
  else
     if hasDisclaimer
       I "#{tlp} has Incubator disclaimer"
     else
       E "#{tlp} does not have Incubator disclaimer"
     end
  end

  if body.include? 'dist.apache.org'
    E 'Page must not link to dist.apache.org'
  else
    I 'Page does not reference dist.apache.org'
  end

  if body.include? 'repository.apache.org'
    E 'Page must not link to repository.apache.org'
  else
    I 'Page does not reference repository.apache.org'
  end

  deprecated = Time.parse('2018-01-01')
  
  links = get_links(body)
  
  # check KEYS link
  # TODO: is location used by hc allowed, e.g.
  #   https://www.apache.org/dist/httpcomponents/httpclient/KEYS
  expurl = "https://[downloads.|www.]apache.org/[dist/][incubator/]#{tlp}/KEYS"
  expurlre = %r{^https://((www\.)?apache\.org/dist|downloads\.apache\.org)/(incubator/)?#{tlp}/KEYS$}
  keys = links.select{|h,v| h =~ expurlre}
  if keys.size >= 1
    keyurl = keys.first.first
    keytext = keys.first[1]
    if keytext.strip == 'KEYS'
        I 'Found KEYS link'
    else
        W "Found KEYS: '#{keytext}'"
    end
    check_head(keyurl,:E, "200", false, true)
  else
    keys = links.select{|h,v| v.strip == 'KEYS' || v == 'KEYS file' || v == '[KEYS]'}
    if keys.size >= 1
      I 'Found KEYS link'
      keyurl = keys.first.first
      if keyurl =~ expurlre
        I "KEYS links to #{expurl} as expected"
      else
        if keyurl =~ %r{^https://www\.apache\.org/dist/#{tlp}/[^/]+/KEYS$}
          W "KEYS: expected: #{expurl}\n             actual: #{keyurl}"
        elsif keyurl =~ %r{^https://downloads\.apache\.org/#{tlp}/[^/]+/KEYS$}
          W "KEYS: expected: #{expurl}\n             actual: #{keyurl}"
        else
          E "KEYS: expected: #{expurl}\n             actual: #{keyurl}"
        end
      end
      check_head(keyurl,:E, "200")
    else
      E 'Could not find KEYS link'
    end
  end
  
  # check for verify instructions
  bodytext = body.gsub(/\s+/,' ') # single line
  if VERIFY_TEXT.any? {|text| bodytext.include? text}
    I 'Found reference to download verification'
  else
    E 'Could not find statement of the need to verify downloads'
  end
  
  # Check if GPG verify has two parameters
  body.scan(%r{^.+gpg --verify.+$}){|m|
    unless m =~ %r{gpg --verify\s+\S+\.asc\s+\S+}
      W "gpg verify should specify second param: #{m.strip} see:\nhttps://www.apache.org/info/verification.html#specify_both"
    end
  }
  
  # check if page refers to md5sum
  body.scan(%r{^.+md5sum.+$}){|m|
    W "Found md5sum: #{m.strip}"
  }
  
  # Check archives have hash and sig
  vercheck = Hash.new() # key = archive name, value = array of hash/sig

  links.each do |h,t|
    # These might also be direct links to mirrors
    if h =~ ARTIFACT_RE
        base = File.basename($1)
  #         puts "base: " + base
        if vercheck[base]  # might be two links to same archive
            W "Already seen link for #{base}"
        else
            vercheck[base] = [h =~ %r{^https?://archive.apache.org/} ? 'archive' : 'live']
        end
        # Text must include a '.' (So we don't check 'Source')
        if t.include?('.') and not base == File.basename(t.strip.downcase)
          # text might be short version of link
          tmp = t.strip.sub(%r{.*/},'').downcase # 
          if base == tmp
            W "Mismatch?: #{h} and '#{t}'"
          elsif base.end_with? tmp
            W "Mismatch?: #{h} and '#{tmp}'"
          elsif base.sub(/-bin\.|-src\./,'.').end_with? tmp
            W "Mismatch?: #{h} and '#{tmp}'"
          else
            W "Mismatch2: #{h} and '#{tmp}'"
          end
        end        
    end
  end

  links.each do |h,t|
    # Must occur before mirror check below
    if h =~ %r{^https?://(?:(?:archive\.|www\.)?apache\.org/dist|downloads\.apache\.org|repo\.maven\.apache\.org/maven2/.+?)/(.+\.(asc|sha\d+|md5|sha))$}
        base = File.basename($1)
        ext = $2
        stem = base[0..-(2+ext.length)]
        if vercheck[stem]
          vercheck[stem] << ext
        else
          E "Bug: found hash #{h} for missing artifact #{stem}"
        end
        t.strip!
        next if t == '' # empire-db
        tmp = text2ext(t)
        next if ext == tmp # i.e. link is just the type or [TYPE]
        next if ext == 'sha' and tmp == 'sha1' # historic
        next if (ext == 'sha256' or ext == 'sha512') and (t == 'SHA' or t == 'digest') # generic
        if not base == t and not t == 'checksum'
            E "Mismatch: #{h} and '#{t}'"
        end
    end
  end

  
  # did we find all required elements?
  vercheck.each do |k,v|
    typ = v.shift
    unless v.include? "asc" and v.any? {|e| e =~ /^sha\d+$/ or e == 'md5' or e == 'sha'}
      if typ == 'live'
        E "#{k} missing sig/hash: (found only: #{v.inspect})"
      elsif typ == 'archive'
        W "#{k} missing sig/hash: (found only: #{v.inspect})"
      else
        E "#{k} missing sig/hash: (found only: #{v.inspect}) TYPE=#{typ}"
      end
    end
  end

  if @fails > 0 and not $ALWAYS_CHECK_LINKS
    W "** Not checking links **"
    $NOFOLLOW = true
  end

  # Check if the links can be read

  links.each do |h,t|
    if h =~ %r{\.(asc|sha256|sha512)$}
      host, stem, ext = check_hash_loc(h,tlp)
      if host == 'archive'
        if $ARCHIVE_CHECK
          check_head(h, :E, "200", true, true)
        else
          I "Ignoring archive hash #{h}"
        end
      elsif host
        if $NOFOLLOW
          I "Skipping archive hash #{h}"
        else
          check_head(h, :E, "200", true, true)
        end
      else
        # will have been reported by check_hash_loc
      end
    # mirror downloads need to be treated differently
    elsif h =~ %r{^https?://(www\.)?apache\.org/dyn/.*action=download}
      if $NOFOLLOW
          I "Skipping download artifact #{h}"
      else
          check_closer_down(h)
      end
    elsif h =~ ARTIFACT_RE
      if $NOFOLLOW
        I "Skipping archive artifact #{h}"
        next
      end
      name = $1
      ext = $2
      if h =~ %r{https?://archive\.apache\.org/}
        unless $ARCHIVE_CHECK
            I "Ignoring archive artifact #{h}"
            next
        end
      end
      # Ideally would like to check for use of closer.lua/.cgi, but some projects pre-populate the pages
      # TODO: would it help to check host against mirrors.list?
      if h =~ %r{https?://(www\.)?apache\.org/dist} or h =~ %r{https?://downloads.apache.org/}
        E "Must use mirror system #{h}"
        next
      end
      res = check_head(h, :E, "200", false)
      next unless res
      # if HEAD returns content_type and length it's probably a direct link
      ct = res.content_type
      cl = res.content_length
      if ct and cl
        I "#{h} OK: #{ct} #{cl}"
      else # need to try to download the mirror page
        path = nil
        bdy = check_page(h, :E, "200", false)
        if bdy
          lks = get_links(bdy)
          lks.each do |l,t|
             # Don't want to match archive server (closer.cgi defaults to it if file is not found)
             if l.end_with?(name) and l !~ %r{//archive\.apache\.org/}
                path = l
                break
             end
          end
        end
        if path
          res = check_head(path, :E, "200", false)
          next unless res
          ct = res.content_type
          cl = res.content_length
          if ct and cl
            I "OK: #{ct} #{cl} #{path}"
          elsif cl
            W "NAK: ct='#{ct}' cl='#{cl}' #{path}"
          else
            E "NAK: ct='#{ct}' cl='#{cl}' #{path}"
          end
        else
          E "Could not find link for '#{name}' in page: '#{h}' (missing or archived)"
        end
      end
    elsif h =~ %r{\.(md5|sha\d*)$}
      host,_,_ = check_hash_loc(h,tlp)
      if $NOFOLLOW
        I "Skipping deprecated hash #{h}"
        next
      end
      if host == 'www' or host == ''
        res = check_head(h,:E, "200", false, true) # allow for redirect here
        next unless res
        lastmod = res['last-modified']
        date = Time.parse(lastmod)
        # Check if older than 2018?
        if date < deprecated
          I "Deprecated hash found #{h} #{t}; however #{lastmod} is older than #{deprecated}"
          # OK
        else
          W "Deprecated hash found #{h} #{t} - do not use for current releases #{lastmod}"
        end
      end
    elsif h =~ %r{/KEYS$} or t == 'KEYS'
      # already handled
    elsif h =~ %r{^https?://www\.apache\.org/?(licenses/.*|foundation/.*|events/.*)?$}
      # standard links
    elsif h =~ %r{https?://people.apache.org/phonebook.html}
    elsif h.start_with? 'https://cwiki.apache.org/confluence/'
      # Wiki
    elsif h.start_with? 'https://wiki.apache.org/'
      # Wiki
    elsif h.start_with? 'https://svn.apache.org/'
      #        E "Public download pages should not link to unreleased code: #{h}" # could be a sidebar/header link
    elsif h =~ %r{^https?://(archive|www)\.apache\.org/dist/}
      W "Not yet handled #{h} #{t}" unless h =~ /RELEASE[-_]NOTES/ or h =~ %r{^https?://archive.apache.org/dist/#{tlp}/}
    else
      # Ignore everything else?
    end
  end

end

def getTLP(url) # convert URL to TLP/podling
  if url =~ %r{^https?://cwiki\.apache\.org/confluence/display/([\S]+)/}
      tlp = $1.downcase
  elsif url =~ %r{^https?://([^.]+)(\.incubator|\.us|\.eu)?\.apache\.org/}
     tlp = URL2TLP[$1] || $1
  elsif url =~ %r{^https?://([^.]+)\.openoffice\.org/}
     tlp = 'openoffice'
  else
     tlp = nil
     F "Unknown TLP for URL #{url}"
  end
  tlp
end

# Called by GUI when POST is pushed
def doPost(options)
  $ALWAYS_CHECK_LINKS = options[:checklinks]
  $NO_CHECK_LINKS = options[:nochecklinks]
  $ARCHIVE_CHECK = options[:archivecheck]
  init
  url = options[:url]
  tlp = options[:tlp]
  tlp = getTLP(url) if tlp == ''
  if tlp
    checkDownloadPage(url, tlp, options[:version])
  end
  displayHTML
end


if __FILE__ == $0
  $CLI = true
  $SAFE = 0
  $VERBOSE =true
  $ALWAYS_CHECK_LINKS = ARGV.delete '--always'
  $NO_CHECK_LINKS = ARGV.delete '--nolinks'
  $ARCHIVE_CHECK = ARGV.delete '--archivecheck'
  $ALLOW_HTTP = ARGV.delete '--http'

  # check for any unhandled options
  ARGV.each do |arg|
    raise ArgumentError.new("Invalid option #{arg}") if arg.start_with? '--'
  end

  init

  version = ''
  if ARGV.size == 1
    url = ARGV[0]
    tlp = getTLP(url)
  else
    url = ARGV[0]
    tlp = ARGV[1]
    version = ARGV[2] || ''
  end

  checkDownloadPage(url, tlp, version)

  # display the test results as text
  puts ""
  puts "================="
  puts ""
  @tests.each { |t| t.map{|k, v| puts "#{k}: - #{v}"}}
  puts ""
  testentries(:W).each { |t| t.map{|k, v| puts "#{k}: - #{v}"}}
  testentries(:E).each { |t| t.map{|k, v| puts "#{k}: - #{v}"}}
  testentries(:F).each { |t| t.map{|k, v| puts "#{k}: - #{v}"}}
  puts ""
  if @fails > 0
    puts "NAK: #{url} had #{@fails} errors"
  else
    puts "OK: #{url} passed all the tests"
  end
  puts ""
end
