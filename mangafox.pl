#!/usr/bin/env perl
package mf;
use v5.10;
use AnyEvent::Util;
use AnyEvent::HTTP;
use common::sense;
use IO::All;
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Spec;
use Mojo::DOM;

sub DEBUG() { $ENV{DEBUG} // 1 }
sub CACHE() { $ENV{CACHE} // 1 }
sub MAX_ACTIVE_REQUESTS() { $ENV{MAX_ACTIVE_REQUESTS} // 5 }

BEGIN {
	if (DEBUG) {
		require common::sense;
		require Digest::SHA1;
		Digest::SHA1->import('sha1_hex');
		common::sense->import;
	}
}

my $active_requests;
my $baseurl = 'http://www.mangafox.com';
my @backlog;
my $cv = AE::cv;
my $dir = join '/', File::Spec->splitdir(dirname(__FILE__));

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

sub _make_cb {
	my $caller_cb = shift;
	return unless $caller_cb;
	my $guard = guard { &$caller_cb };
	sub {$guard};
}

sub mf_manga($;&) {
	my ($mangaurl, $cb) = @_;
	my $chapter_cb = _make_cb($cb);
	http $mangaurl, sub {
		dom(shift)->find('a.ch')->each(sub {
			mf_chapter($baseurl . shift->attrs->{href}, $chapter_cb);
		});
	};
}

sub mf_chapter($;&) {
	my ($page1url, $cb) = @_;
	my $guard = guard { &$cb };
	(my $chapter_url = $page1url) =~ s/[^\/]+$//;
	http $page1url, sub {
		my $page1 = dom(shift);
		my $chapter_title;
		
		$page1->find('#image')->each(sub {
			my $img = shift->attrs;
			$chapter_title = $img->{alt};
			$chapter_title =~ tr!\?"/\\<>\|:\*!？”∕＼＜＞｜：＊!;
			$chapter_title =~ s!(.+?) (Vol.\S+) (Ch.[^：]+)： (.+?) at MangaFox.com!$1/$2/$3 - $4!;
			$chapter_title =~ s/\.$//;
			unless (-d $chapter_title) {
				say "Making path: $chapter_title" if DEBUG;
				make_path $chapter_title;
			}

			unless (-f "$chapter_title/01.jpg") {
				_http $img->{src}, sub {
					my $imgbuf = shift;
					io("$chapter_title/01.jpg")->binary->print($imgbuf);
					$guard;
				};
			}
		});

		my @pages;
		$page1->find('#pgnav > p > a')->each(sub {
			my $a = shift;
			push @pages, [$a->text, $a->attrs->{href}];
		});
		my $digits = length @pages[-1]->[0];
		my $spf = '%0' . $digits . 'd';
		while (my ($pagenum, $href) = @{shift @pages}) {
			$pagenum = sprintf $spf, $pagenum;
			return if -f "$chapter_title/$pagenum.jpg";
			
			http $chapter_url . $href, sub {
				dom(shift)->find('#image')->each(sub {
					my $img = shift->attrs;
					_http $img->{src}, sub {
						my $imgbuf = shift;
						io("$chapter_title/$pagenum.jpg")->binary->print($imgbuf);
						$guard;
					};
				});
			};
		}
	};
}

sub cli_parse(@) {
	return say 'No arguments. Paste some mangafox manga urls.' if !@_;
	my $guard = guard { $cv->send };
	for (@_) {
		if (m!$baseurl/manga/\w+/v\d+/c\d+!) {
			mf_chapter $_, sub {$guard};
		}
		elsif (m!$baseurl/manga/\w+!) {
			mf_manga $_, sub {$guard};
		}
		else {
			say "I don't understand '$_'!";
		}
	}
}

cli_parse(@ARGV);
$cv->recv;

