use 5.006;
use strict;
use inc::Module::Install;
name 'Test-POE-Client-TCP';
author 'Chris Williams <chris@bingosnet.co.uk>';
version_from 'lib/Test/POE/Client/TCP.pm';
abstract_from 'lib/Test/POE/Client/TCP.pm';
license 'perl';
perl_version '5.006';
build_requires 'Test::More' => 0.47;
build_requires 'Text::ParseWords' => 0;
requires 'POE' => 1.004;
requires 'POE::Wheel::SocketFactory' => 0;
requires 'POE::Filter::Line' => 0;
requires 'POE::Wheel::ReadWrite' => 0;
requires 'POE::Filter' => 0;
auto_set_repository;
WriteAll();