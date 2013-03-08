#!/usr/bin/perl

package RT::Action::SMSNotify;
use 5.10.1;
use strict;
use warnings;

use Data::Dumper;
use SMS::Send;

use base qw(RT::Action);

=pod

=head1 NAME

RT::Action::SMSNotify

=head1 DESCRIPTION

See L<RT::Extension::SMSNotify> for details

This action may be invoked directly, from rt-crontool, or via a Scrip.

=head1 ARGUMENTS

C<RT::Action::SMSNotify> takes a single argument, like all other RT actions.
The argument is a comma-delimited string of codes indicating where the module
should get phone numbers to SMS from. Wherever a group appers in a category,
all the users from that group will be recursively added.

Recognised codes are:

=head2 TicketRequestors

The ticket requestor(s). May be groups.

=head2 TicketCc

All entries in the ticket Cc field

=head2 TicketAdminCc

All entires in the ticket AdminCc field

=head2 TicketOwner

The ticket Owner field

=head2 QueueCc

All queue watchers in the Cc category on the queue

=head2 QueueAdminCc

All queue watchers in the AdminCc category on the queue

=head2 g:name

The RT group with name 'name'. Ignored with a warning if it doesn't exist.
No mechanism for escaping commas in names is provided.

NOT YET IMPLEMENTED

=head2 p:number

A phone number, specified in +0000000 form with no spaces, commas etc.

=cut

sub _ArgToUsers {
	# Convert one of the argument codes into an array of users.
	# If it's one of the predefined codes, looks up the users object for it;
	# otherwise looks for a u: or g: prefix for a user or group name or
	# for a p: prefix for a phone number.
	#
	# returns a 2-tuple where one part is always undef. 1st part is
	# arrayref of RT::User objects, 2nd part is a phone number from a p:
	# code as a string.
	#
	my $ticket = shift;
	my $name = shift;
	my $queue = $ticket->QueueObj;
	# To be set to an arrayref of members
	my $m = undef;
	# To be set to a scalar phone number from p:
	my $p = undef;
	for ($name) {
		when (/^TicketRequestors?$/) {
			$m = $ticket->Requestors->UserMembersObj->ItemsArrayRef;
		}
		when (/^TicketCc$/) {
			$m = $ticket->Cc->UserMembersObj->ItemsArrayRef;
		}
		when (/^TicketAdminCc$/) {
			$m = $ticket->AdminCc->UserMembersObj->ItemsArrayRef;
		}
		when (/^TicketOwner$/) {
			$m = $ticket->Owner->UserMembersObj->ItemsArrayRef;
		}
		when (/^QueueCc$/) {
			$m = $queue->Cc->UserMembersObj->ItemsArrayRef;
		}
		when (/^QueueAdminCc$/) {
			$m = $queue->AdminCc->UserMembersObj->ItemsArrayRef;
		}
		when (/^g:/) { 
			my $g = RT::Group->new($RT::SystemUser);
			$g->LoadUserDefinedGroup(substr($name,2));
			$m = $g->UserMembersObj->ItemsArrayRef;
		}
		when (/^p:/) { $p = substr($name, 2); }
		default {
			RT::Logger->error("Unrecognised argument $name, ignoring");
		}
	}
	die("Assertion that either \$m or \$p is undef violated") if (defined($m) == defined($p));
	return $m, $p;
}

sub _AddPagersToRecipients {
	# Takes hashref of { userid => userobject } form and an arrayref of
	# RT::User objects to merge into it if the user ID isn't already
	# present.
	my $destusers = shift;
	my $userstoadd = shift;
	for my $u (@$userstoadd) {
		$destusers->{$u->Id} = $u;
	}
}
sub _GetPagerNumberForUserFilter {
	# This is a function so it can be overridden in the config to use
	# database lookups or whatever. 2nd argument (the RT::Ticket object if any)
	# is ignored.
	return $_[0]->PagerPhone;
}

sub Prepare {
	my $self = shift;

	if (!$self->Argument) {
		RT::Logger->error("Argument to RT::Action::SMSNotify required, see docs");
		return 0;
	}

	my $getpagerfn = RT->Config->Get('SMSNotifyGetPhoneForUserFn') // _GetPagerNumberForUserFilter;

	my $ticket = $self->TicketObj;
	my $destusers = {};
	my @numbers = ();
	foreach my $argpart (split(',', $self->Argument)) {
		my ($userarray, $phoneno) = _ArgToUsers($ticket, $argpart);
		_AddPagersToRecipients($destusers, $userarray) if defined($userarray);
		push(@numbers, $phoneno) if defined($phoneno);
	}
	# For each unique user to be notified, get their phone number(s) using
	# the $SMSNotifyGetPhoneForUserFn mapping function and add all defined
	# results to the numbers array.
	push(@numbers, grep length, map &{$getpagerfn}($_, $ticket), values %$destusers);

	RT::Logger->info("Preparing to send SMSes to: " . Dumper(@numbers) );

	$self->{'PagerNumbers'} = \@numbers;

	return scalar(@numbers);
}

sub Commit {

	my $self = shift;

	my @memberlist = @{$self->{'PagerNumbers'}};

	my $sender = SMS::Send->new( RT->Config->Get('SMSNotifyProvider'), %{RT->Config->Get('SMSNotifyArguments')});
	foreach my $ph (@memberlist) {

		# TODO: Sub in principal of current $ph
		my ($result, $message) = $self->TemplateObj->Parse(
			Argument       => $self->Argument,
			TicketObj      => $self->TicketObj,
			TransactionObj => $self->TransactionObj
		);
		if ( !$result ) {
			$RT::Logger->error("Failed to populate template: $result, $message");
			next;
		}

		my $MIMEObj = $self->TemplateObj->MIMEObj;
		my $msgstring = $MIMEObj->bodyhandle->as_string;

		eval {
			$RT::Logger->debug("Notifying $ph about ticket SLA");
			$sender->send_sms(
				text => $msgstring,
				to   => $ph
			);
			$RT::Logger->info("Notified $ph about ticket SLA");
		};
		if ($@) {
			$RT::Logger->error("Failed to notify $ph about ticket SLA: $@");
		}
	}

	return 1;
}

1;

