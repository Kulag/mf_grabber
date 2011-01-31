#!/usr/bin/env perl
package mf;

use v5.10;
use File::Basename 'dirname';
use File::Spec;
use EV;
use IO::All;
use AnyEvent::HTTP;
use Mojo::DOM;

my $dir = join '/', File::Spec->splitdir(dirname(__FILE__));

sub DEBUG() { $ENV{DEBUG} // 1 }
sub CACHE() { $ENV{CACHE} // 1 }
sub MAX_ACTIVE_REQUESTS() { $ENV{MAX_ACTIVE_REQUESTS} // 5 }
my $active_requests;
my $baseurl = 'http://www.mangafox.com';

BEGIN {
	if (DEBUG) {
		require common::sense;
		require Digest::SHA1;
		Digest::SHA1->import('sha1_hex');
		common::sense->import;
	}
}

my @backlog;
sub _http($&;$) {
	if ($active_requests >= MAX_ACTIVE_REQUESTS) {
		push @backlog, [@_];
		return;
	}

	my ($url, $cb, $cfile) = @_;

	$active_requests++;

	DEBUG and say "GET $url";
	http_get $url, recurse => 10, sub {
		my ($data, $headers) = @_;
		DEBUG and say "GOT $url";

		die "http error: $headers->{Status} $headers->{Reason}" unless $headers->{Status} =~ /^2/;
		$data > io($cfile) if $cfile;

		$active_requests--;
		$cb->($data);
		_http(@{shift @backlog}) if @backlog;
	};
}

sub http($&;$) {
	my $url = shift;
	my $cb = shift;
	my $cache = shift // CACHE;
	
	my $cfile;
	if ($cache) {
		# Check our cache for the file first.
		my $cid = sha1_hex($url);
		$cfile = "$dir/cache/$cid";
		if (-f $cfile) {
			my $buf < io($cfile);
			DEBUG and say "CACHED $url";
			$cb->($buf);
			return;
		}
	}
	
	_http($url, \&$cb, $cfile);
}

sub dom($) { Mojo::DOM->new->parse(shift) }

sub mf_manga($) {
	my $mangaurl = shift;
	http $mangaurl, sub {
		dom(shift)->find('a.chico')->each(sub { mf_chapter($baseurl . shift->attrs->{href}) });
	};
}

sub mf_chapter($) {
	my $page1url = shift;
	http $page1url, sub {
		my $page1 = dom(shift);
		my $chapter_title;
		
		$page1->find('#image')->each(sub {
			$chapter_title = shift->attrs->{alt};
			$chapter_title =~ tr!\?"/\\<>\|:\*!？”∕＼＜＞｜：＊!;
			mkdir $chapter_title;
		});
		
		$page1->find('select.middle > option')->each(sub {
			my $pagenum = shift->attrs->{value};
			
			return if -f "$chapter_title/$pagenum.jpg";
			
			http $page1url . $pagenum . '.html', sub {
				dom(shift)->find('img#image')->each(sub {
					my $img = shift->attrs;
					_http $img->{src}, sub {
						my $imgbuf = shift;
						io("$chapter_title/$pagenum.jpg")->binary->print($imgbuf);
					};
				});
			};
		});
	};
}

sub cli_parse(@) {
	return say 'No arguments. Paste some mangafox manga urls.' if !@_;
	for (@_) {
		if (m!$baseurl/manga/\w+/v\d+/c\d+!) {
			mf_chapter $_;
		}
		elsif (m!$baseurl/manga/\w+!) {
			mf_manga $_;
		}
		else {
			say "I don't understand '$_'!";
		}
	}
}

cli_parse(@ARGV);
EV::loop;
