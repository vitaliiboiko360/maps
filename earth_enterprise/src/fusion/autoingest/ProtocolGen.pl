#!/usr/bin/perl -w-
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use strict;
use FindBin;
use Getopt::Long;
use File::Basename;


my $proxyh;
my $proxycpp;
my $handlercpp;
my $static;
my $notry = 0;
my $dispatchthunks = 0;
my $handlerclass;
my $help = 0;
my $thiscommand = "@ARGV";

sub usage() {
    die "usage: $FindBin::Script <mode> <outfile> <protocol file>\n" .
	"       Where <mode> is one of:\n".
	"       --proxyh\n".
	"       --proxycpp\n".
	"       --handlercpp\n";
}
GetOptions("proxyh=s"     => \$proxyh,
	   "proxycpp=s"   => \$proxycpp,
	   "handlercpp=s" => \$handlercpp,
	   "static"       => \$static,
	   "notry"        => \$notry,
	   "dispatchthunks" => \$dispatchthunks,
	   "handlerclass=s" => \$handlerclass,
	   "help|?"    => \$help) || usage();
usage() if $help;
usage() unless (defined($proxyh) || defined($proxycpp) ||
		defined($handlercpp));

if ($static) {
    $static = 'static ';
} else {
    $static = '';
}

my $infile = shift;

my $class;
my @includes = ();
my @notify = ();
my @request = ();
my $currlist = \@request;
open(IN, $infile) || die "Unable to open $infile: $!\n";
while (<IN>) {
    chomp;
    s,//.*$,,;		# strip c++ comments from end of line
    next if (/^\s*$/);


    if (/^\s*class\s+(\w+)\s*\{\s*$/) {
	$class = $1;
    } elsif (/^\s*\#include/) {
	push @includes, $_;
    } elsif (/^\s*notify:/) {
	$currlist = \@notify;
    } elsif (/^\s*request:/) {
	$currlist = \@request;
    } elsif (/^\s*(\S+)\s+([^\(\s]+)\s*\(\s*const\s+([^\s&]+)\s*&\s*([^\)]+)?\s*\)\s*;\s*$/) {
	my $rettype = $1;
	my $cmdname = $2;
	my $argtype = $3;
	my $argname = $4;
	$argname = 'arg' unless $argname;

	if (($currlist eq \@notify) && ($rettype ne 'void')) {
	    die "$infile:$.: Return type for notify functions must be 'void'\n";
	}

	push @{$currlist}, { rettype => $rettype,
			     cmdname => $cmdname,
			     argtype => $argtype,
			     argname => $argname };
    } elsif (/^\s*\}\s*;\s*$/) {
	next;
    } else {
	die "$infile:$.: Unrecognized line in protocol file\n";
    }
}
close(IN);


# ****************************************************************************
# ***  proxyh
# ****************************************************************************
if ($proxyh) {
    EnsureDirExists($proxyh);
    my $fh;
    my $hprot = basename($proxyh);
    $hprot =~ tr/./_/;
    chmod 0777, $proxyh;
    open($fh, "> $proxyh") || die "Unable to open $proxyh: $!\n";
    EmitAutoGeneratedWarning($fh);

    print $fh <<EOF;
#ifndef __$hprot
#define __$hprot

EOF

    foreach my $include (@includes) {
	print $fh $include, "\n";
    }

    if ($static) {
print $fh <<EOF;
#include <QtCore/qstring.h>

class ${class}Proxy {
public:
EOF
    } else {
print $fh <<EOF;
#include <autoingest/FusionConnection.h>

class ${class}Proxy {
    FusionConnection::Handle conn;
public:
    ${class}Proxy(const FusionConnection::Handle &conn_) : conn(conn_) { }
    FusionConnection::Handle& connection(void) { return conn; }

EOF
    }
    if (@notify) {
	print $fh "    // notify routines\n";
	foreach my $notify (@notify) {
	    if ($notry) {
		printf($fh "    ${static}void %s(const %s &%s, int timeout = 0);\n",
		       $notify->{cmdname},
		       $notify->{argtype}, $notify->{argname});
	    } else {
		printf($fh "    ${static}bool %s(const %s &%s, QString &error, int timeout = 0) throw();\n",
		       $notify->{cmdname},
		       $notify->{argtype}, $notify->{argname});
	    }
	}
	print $fh "\n";
    }

    if (@request) {
	print $fh "    // request routines\n";
	foreach my $request (@request) {
	    if ($notry) {
		printf($fh "    ${static}void %s(const %s &%s%s, int timeout = 0);\n",
		       $request->{cmdname}, $request->{argtype}, $request->{argname},
		       ($request->{rettype} eq 'void') ? '' : ", $request->{rettype} &ret");
	    } else {
		printf($fh "    ${static}bool %s(const %s &%s%s, QString &error, int timeout = 0) throw();\n",
		       $request->{cmdname}, $request->{argtype}, $request->{argname},
		       ($request->{rettype} eq 'void') ? '' : ", $request->{rettype} &ret");
	    }
	}
	print $fh "\n";
    }

    print $fh <<EOF;
};

#endif /* __$hprot */
EOF

    close($fh);
    chmod 0444, $proxyh;
}


# ****************************************************************************
# ***  proxycpp
# ****************************************************************************
if ($proxycpp) {
    EnsureDirExists($proxycpp);
    my $fh;
    chmod 0777, $proxycpp;
    my $proxyh = basename($proxycpp);
    $proxyh =~ s/\..+$/\.h/;

    open($fh, "> $proxycpp") || die "Unable to open $proxycpp: $!\n";
    EmitAutoGeneratedWarning($fh);

    print $fh "#include \"$proxyh\"\n";
    print $fh "#include <autoingest/FusionConnection.h>\n";
    if ($static) {
        print $fh "#include <QtCore/qstring.h>\n";
    }
    print $fh "\n\n";

    foreach my $notify (@notify) {
	my $cmdname = $notify->{cmdname};
	my $argtype = $notify->{argtype};
	my $argname = $notify->{argname};
        my $getconn = '';
        if ($static) {
	    if ($notry) {
		$getconn = <<EOF;
    FusionConnection::Handle conn(FusionConnection::ConnectTo${class}());
EOF
            } else {
		$getconn = <<EOF;
    FusionConnection::Handle conn(FusionConnection::TryConnectTo${class}(error));
    if (!conn) {
	return false;
    }
EOF
	    }
        }
        
        if ($notry) {
	  print $fh <<EOF;
void
${class}Proxy::$cmdname(const $argtype &$argname, int timeout)
{
$getconn
    conn->Notify("$cmdname", $argname, timeout);
}
	
EOF
        } else {
	  print $fh <<EOF;
bool
${class}Proxy::$cmdname(const $argtype &$argname, QString &error, int timeout) throw()
{
$getconn
    return conn->TryNotify("$cmdname", $argname, error, timeout);
}
	
EOF
        }

    }
    
    foreach my $request (@request) {
	my $cmdname = $request->{cmdname};
	my $argtype = $request->{argtype};
	my $argname = $request->{argname};
        my $rettype = $request->{rettype};
        my $getconn = '';
        if ($static) {
	    if ($notry) {
		$getconn = <<EOF;
    FusionConnection::Handle conn(FusionConnection::ConnectTo${class}());
EOF
            } else {
		$getconn = <<EOF;
    FusionConnection::Handle conn(FusionConnection::TryConnectTo${class}(error));
    if (!conn) {
	return false;
    }
EOF
	    }
        }

        if ($rettype eq 'void') {
	    if ($notry) {
		print $fh <<EOF;
void
${class}Proxy::$cmdname(const $argtype &$argname, int timeout)
{
$getconn
    conn->TryNoRetRequest("$cmdname", $argname, timeout);
}

EOF
            } else {
		print $fh <<EOF;
bool
${class}Proxy::$cmdname(const $argtype &$argname, QString &error, int timeout) throw()
{
$getconn
    return conn->TryNoRetRequest("$cmdname", $argname, error, timeout);
}

EOF
            }
	} else {
	    if ($notry) {
                print $fh <<EOF;
void
${class}Proxy::$cmdname(const $argtype &$argname, $rettype &ret, int timeout)
{
$getconn
    conn->TryRequest("$cmdname", $argname, ret, timeout);
}

EOF
            } else {
                print $fh <<EOF;
bool
${class}Proxy::$cmdname(const $argtype &$argname, $rettype &ret, QString &error, int timeout) throw()
{
$getconn
    return conn->TryRequest("$cmdname", $argname, ret, error, timeout);
}

EOF
            }
	}
    }
    

    close($fh);
    chmod 0444, $proxycpp;
}


# ****************************************************************************
# ***  handlercpp
# ****************************************************************************
if ($handlercpp) {
    $handlerclass = $class unless defined($handlerclass);

    EnsureDirExists($handlercpp);
    my $fh;
    chmod 0777, $handlercpp;

    open($fh, "> $handlercpp") || die "Unable to open $handlercpp: $!\n";
    EmitAutoGeneratedWarning($fh);

    print $fh "#include \"${handlerclass}.h\"\n";
    print $fh "#include <khException.h>\n";
    print $fh "#include <khstrconv.h>\n";

    print $fh "\n\n";
    print $fh "void\n${handlerclass}::DispatchNotify(const FusionConnection::RecvPacket &msg)\n";
    print $fh "{\n";
    if (@notify) {
	print $fh "    std::string cmdname = msg.cmdname();\n";
	my $first = 1;
	foreach my $notify (@notify) {
            if ($first) {
	        $first = 0;
	        print $fh "    if (cmdname == \"$notify->{cmdname}\") {\n";
	    } else {
	        print $fh "    } else if (cmdname == \"$notify->{cmdname}\") {\n";
	    }
	    print $fh <<EOF;
        $notify->{argtype} $notify->{argname};
	if (FromPayload(msg.payload, $notify->{argname})) {
EOF
            if ($dispatchthunks) {
	        print $fh "            DispatchThunk(std::mem_fun(&${handlerclass}::$notify->{cmdname}),$notify->{argname});\n";
	    } else {
	        print $fh "            $notify->{cmdname}($notify->{argname});\n";
	    }
	    print $fh <<EOF;
	} else {
	    throw khException(kh::tr("Unable to decode %1 payload")
                              .arg(ToQString(cmdname)));
	}
EOF
        }
        print $fh "    } else {\n";
        print $fh "        throw khException(kh::tr(\"Unrecognized notify command: \")\n";
        print $fh "                          + ToQString(cmdname));\n";
        print $fh "    }\n";
    }
    print $fh "}\n";


    print $fh "\n\n";
    print $fh "void\n${handlerclass}::DispatchRequest(const FusionConnection::RecvPacket &msg, std::string &replyPayload)\n";
    print $fh "{\n";
    if (@request) {
	print $fh "    std::string cmdname = msg.cmdname();\n";
	my $first = 1;
	foreach my $request (@request) {
            if ($first) {
	        $first = 0;
	        print $fh "    if (cmdname == \"$request->{cmdname}\") {\n";
	    } else {
	        print $fh "    } else if (cmdname == \"$request->{cmdname}\") {\n";
	    }
            print $fh "        $request->{argtype} $request->{argname};\n";
            print $fh "        if (FromPayload(msg.payload, $request->{argname})) {\n";
	    if ($request->{rettype} ne 'void') {
                print $fh "            $request->{rettype} ret;\n";
	        if ($dispatchthunks) {
		    print $fh "            DispatchThunk(std::mem_fun(&${handlerclass}::$request->{cmdname}),$request->{argname}, ret);\n";
	        } else {
		    print $fh "            $request->{cmdname}($request->{argname}, ret);\n";
	        }

	        print $fh <<EOF
            if (!ToPayload(ret, replyPayload)) {
		throw khException(kh::tr("Unable to encode %1 reply payload")
				  .arg(ToQString(cmdname)));
	    }
EOF
	    } else {
	        if ($dispatchthunks) {
		    print $fh "            DispatchThunk(std::mem_fun(&${handlerclass}::$request->{cmdname}),$request->{argname});\n";
	        } else {
		    print $fh "            $request->{cmdname}($request->{argname});\n";
	        }
	    }
	    print $fh <<EOF;
	} else {
	    throw khException(kh::tr("Unable to decode %1 payload")
                              .arg(ToQString(cmdname)));
	}
EOF
        }
        print $fh "    } else {\n";
        print $fh "        throw khException(kh::tr(\"Unrecognized notify command: \")\n";
        print $fh "                          + ToQString(cmdname));\n";
        print $fh "    }\n";
    }
    print $fh "}\n\n";

    close($fh);
    chmod 0444, $handlercpp;
}


sub EmitAutoGeneratedWarning
{
    my ($fh, $cs) = @_;
    $cs = '//' unless defined $cs;
    print $fh <<WARNING;
$cs ***************************************************************************
$cs ***  This file was AUTOGENERATED with the following command:
$cs ***
$cs ***  $FindBin::Script $thiscommand
$cs ***
$cs ***  Any changes made here will be lost.
$cs ***************************************************************************
WARNING
}

sub EnsureDirExists
{
    my $dir = dirname($_[0]);
    if (! -d $dir) {
	EnsureDirExists($dir);
	mkdir($dir) || die "Unable to mkdir $dir: $!\n";
    }
}
