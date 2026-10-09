#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Validates the built Jekyll site (_site) with HTMLProofer.
#
# Scope (by design):
#   * Links to this site (whether written root-relative as "/foo" or absolute as
#     "https://www.getmonero.org/foo") are checked and WILL fail the build. The
#     absolute form is rewritten to root-relative below so it is validated
#     against the built site instead of being skipped as "external".
#   * Links to other hosts (including our own subdomains such as docs./ccs./
#     static.getmonero.org) are treated as external and are NOT checked here.
#     Reaching out over the network would make CI flaky when a third-party site
#     is down; a dedicated non-blocking job can check external links on a
#     schedule instead.
#   * All languages are checked, not just the default one.
#   * Only hyperlink targets (<a href>) are validated. Missing in-page anchors
#     (#fragments) are not gated — the bulk are translated-heading slugs that
#     drift constantly and still land the reader on the right page — and missing
#     images (<img src>) and `alt` attributes are left to separate efforts.
#
# BASELINE:
#   The URLs below are already broken on `master` as of the commit that
#   introduced this check. They are ignored so the check can be added without a
#   simultaneous mass content fix, and so it blocks only *newly* introduced
#   breakage ("ratchet"). They are catalogued upstream in:
#       <!-- TODO: replace with the tracking issue URL before opening the PR -->
#   Entries should be removed from this list as the underlying links are fixed.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "html-proofer"
module HTMLProofer
  module Utils
    def create_nokogiri(path)
      content =
        if File.exist?(path) && !File.directory?(path)
          File.read(path, encoding: "UTF-8")
        else
          path.to_s.dup.force_encoding("UTF-8")
        end

      Nokogiri::HTML5(content.scrub, max_errors: -1)
    end
  end
end

site_dir = ARGV[0] || "_site"

# Matched against the href exactly as written in the HTML, so each pattern is
# left unanchored at the start to match both "/foo" and a stripped absolute URL.
BASELINE_IGNORED_URLS = [
  # Blog posts tag themselves with tags that have no generated tag page yet
  # (tag pages live in /blog/tags/*.md).
  %r{/blog/tags/(ccs|cryptography|dev|development|jamtis|kovri|magic|malware|monero|network upgrade|protocol|seraphis)\.html},

  # Navigation links to pages that no longer exist (or are served only via a
  # redirect that this static check cannot follow).
  %r{/design-goals/?\z},
  %r{/team/?\z},
  %r{/knowledge-base/moneropedia/i2p/?\z},

  # Relative link written without a scheme, so it resolves to a missing local
  # path (should be https://cryptonote.org/whitepaper.pdf).
  %r{cryptonote\.org/whitepaper\.pdf},

  # Link to a release blog post that does not exist in _posts.
  %r{/2026/01/07/monero-0\.18\.4\.5-released\.html},

  # Unrendered Liquid left in content, e.g. a literal "{{ site.baseurl }}/...".
  %r{\{\{\s*site\.baseurl\s*\}\}},

  # Placeholder self-link (".") inside the vendored wallet-generator tool.
  /\A\.\z/,
].freeze

# Rewrite absolute links to our own site into root-relative ones so they are
# validated against the built output instead of being skipped as external.
# Our subdomains (docs./ccs./static./lists.getmonero.org) are intentionally not
# matched, so they remain external.
SELF_URLS = {
  %r{\Ahttps?://(www\.)?getmonero\.org} => "",
  %r{\A//(www\.)?getmonero\.org}        => "",
}.freeze

options = {
  checks: ["Links"],
  disable_external: true,
  enforce_https: false,
  check_internal_hash: false,
  ignore_urls: BASELINE_IGNORED_URLS,
  swap_urls: SELF_URLS,
}

runner = HTMLProofer.check_directory(site_dir, options)

# `run` prints progress and calls exit(1) itself if it finds any failures, so
# code past this line only executes when HTMLProofer reported success.
runner.run

# Guard against a *false* success. If HTMLProofer examined almost no internal
# links, the built site was not actually checked (e.g. an empty or mis-built
# _site, or links emitted in a form HTMLProofer treats as external) and the
# "success" is meaningless. Fail loudly instead of passing silently.
MIN_INTERNAL_LINKS = Integer(ENV.fetch("MIN_INTERNAL_LINKS", "500"))

internal_examined = runner.internal_urls.size
puts "\nLink-check sanity: #{internal_examined} internal links examined."

if internal_examined < MIN_INTERNAL_LINKS
  warn "::error::Link check examined only #{internal_examined} internal links " \
       "(expected at least #{MIN_INTERNAL_LINKS}). The site under '#{site_dir}' " \
       "was not checked as expected — failing instead of reporting a false pass."

  # Diagnostic: show how links are actually written in the build, which
  # distinguishes "pages have no links" from "links are emitted as absolute
  # URLs and therefore skipped as external".
  require "find"
  schemes = Hash.new(0)
  samples = []
  pages = 0
  Find.find(site_dir) do |path|
    next unless path.end_with?(".html")

    pages += 1
    File.read(path).scan(/\shref="([^"]*)"/).each do |(href)|
      bucket =
        case href
        when %r{\Ahttps?://} then "absolute"
        when %r{\A/}         then "root-relative"
        when %r{\A#}         then "in-page-anchor"
        when ""              then "empty"
        else                      "other-relative"
        end
      schemes[bucket] += 1
      samples << href if samples.size < 15
    end
    break if pages >= 50
  end
  warn "href formats across first #{pages} HTML pages: #{schemes.inspect}"
  warn "sample href values: #{samples.inspect}"
  exit(1)
end
