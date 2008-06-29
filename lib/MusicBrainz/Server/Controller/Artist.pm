package MusicBrainz::Server::Controller::Artist;

use strict;
use warnings;
use parent 'Catalyst::Controller';

=head1 NAME

MusicBrainz::Server::Controller::Artist - Catalyst Controller for working with Artist entities

=head1 DESCRIPTION

=head1 METHODS

=cut


=head2 show

Shows an artist's main landing page, showing all of the releases that are attributed to them

=cut

sub show : Path Args(1) {
    my ($self, $c, $mbid) = @_;

    require MusicBrainz;
    require MusicBrainz::Server::Validation;
    require MusicBrainz::Server::Artist;
    require ModDefs;
    use MusicBrainz::Server::Release;

    if($mbid ne "")
    {
	MusicBrainz::Server::Validation::IsGUID($mbid) or $c->error("Not a valid GUID");
    }

    my $mb = new MusicBrainz;
    $mb->Login();

    my $artist = MusicBrainz::Server::Artist->new($mb->{DBH});
    $artist->SetMBId($mbid);
    $artist->LoadFromId(1) or $c->error("Failed to load artist");

    # Load releases
    my @releases = $artist->GetReleases(1, 1);
    my $onlyHasVAReleases = (scalar @releases) == 0;

    my @shortList;

    for my $release (@releases)
    {
	my ($type, $status) = $release->GetReleaseTypeAndStatus;

	# Construct values to sort on
	use Encode qw( decode );

	$release->SetMultipleTrackArtists($release->GetArtist != $release->GetId() ? 1 : 0);
	$release->{_is_va_} = ($release->GetArtist == &ModDefs::VARTIST_ID or
			       $release->GetArtist != $release->GetId());
	$release->{_is_nonalbum_} = ($type == MusicBrainz::Server::Release::RELEASE_ATTR_NONALBUMTRACKS);
	$release->{_section_key_} = ($release->{_is_va_} . " " . $type);
	$release->{_name_sort_} = lc decode "utf-8", $release->GetName;
	$release->{_disc_max_} = 0;
	$release->{_disc_no_} = 0;
	$release->{_firstreleasedate_} = ($release->GetFirstReleaseDate || "9999-99-99");

	CheckAttributes($release);
	
	# Attempt to sort "disc x [of y]" correctly
	if ($release->{_name_sort_} =~
	    /^(.*)                              # $1 <main title>
	        (?:[(]disc\ (\d+)               # $2 (disc x
	            (?:\ of\ (\d+))?            # $3 [of y]
	            (?::[^()]*                  #    [: <disc title>
		        (?:[(][^()]*[)][^()]*)* #     [<1 level of nested par.>]
	            )?                          #    ]
	            [)]                         #    )
	        )
	        (.*)$                           # $4 [<rest of main title>]
	    /xi)
	{
	    $release->{_name_sort_} = "$1 $4";
	    $release->{_disc_no_} = $2;
	    $release->{_disc_max_} = $3 || 0;
	}

	# Push onto our list of releases we are actually interested in
	push @shortList, $release
	    if ($type == MusicBrainz::Server::Release::RELEASE_ATTR_ALBUM ||
		$type == MusicBrainz::Server::Release::RELEASE_ATTR_EP ||
		$type == MusicBrainz::Server::Release::RELEASE_ATTR_COMPILATION ||
		$type == MusicBrainz::Server::Release::RELEASE_ATTR_SINGLE);
    }

    if(scalar @shortList)
    {
	@releases = @shortList;
	@releases = sort SortAlbums @releases;
    }
    else
    {
	$c->error("No releases to show");
    }

    # Create data structures for the template
    #
    # Artist:
    $c->stash->{artist} = {
	name => $artist->GetName,
	type => MusicBrainz::Server::Artist::GetTypeName($artist->GetType) || '',
	datespan => {
	    start => $artist->GetBeginDate,
	    end => $artist->GetEndDate
	},
	quality => ModDefs::GetQualityText($artist->GetQuality),
        resolution => $artist->GetResolution,
    };

    # Releases, sorted into "release groups":
    $c->stash->{groups} = [];

    my $currentGroup;
    for my $release (@releases)
    {
	my ($type, $status) = $release->GetReleaseTypeAndStatus;

	# Releases should have sorted into groups, so if $type has changed, we need to create
	# a new "release group"
	if(not defined $currentGroup or $currentGroup->{type} != $type)
	{
	    $currentGroup = {
			       name => $release->GetAttributeNamePlural($type),
			       releases => [],
			       type => $type
			    };

	    push @{$c->stash->{groups}}, $currentGroup;
	}

	my $rel = {
	    title => $release->GetName,
	    id => $release->GetMBId
	};

	push @{$currentGroup->{releases}}, $rel;
    }

    $c->stash->{template} = 'artist/show.tt';
}

sub CheckAttributes
{
    my ($a) = @_;

    use MusicBrainz::Server::Release;

    for my $attr ($a->GetAttributes)
    {
	$a->{_attr_type} = $attr if ($attr >= MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_TYPE_START &&
				     $attr <= MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_TYPE_END);
	$a->{_attr_status} = $attr if ($attr >= MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_STATUS_START &&
				       $attr <= MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_STATUS_END);
	$a->{_attr_type} = $attr if ($attr == MusicBrainz::Server::Release::RELEASE_ATTR_NONALBUMTRACKS);
    }

    # The "actual values", used for display
    $a->{_actual_attr_type} = $a->{_attr_type};
    $a->{_actual_attr_status} = $a->{_attr_status};

    # Used for sorting
    $a->{_attr_type} = MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_TYPE_END + 1 if (not defined $a->{_attr_type});
    $a->{_attr_status} = MusicBrainz::Server::Release::RELEASE_ATTR_SECTION_STATUS_END + 1 if (not defined $a->{_attr_status});
};

sub SortAlbums
{
    require MusicBrainz::Server::Release;

    # I edited these out of one huge "or"ed conditional as it was a bitch to debug

    my $p1 = $a->{_is_va_} <=> $b->{_is_va_};
    my $p2 = $b->{_is_nonalbum_} <=> $a->{_is_nonalbum_};
    my $p3 = $a->{_attr_type} <=> $b->{_attr_type};

    $p1 or $p2 or $p3 or
      
    ($a->{_firstreleasedate_} cmp $b->{_firstreleasedate_}) or

    ($a->{_name_sort_} cmp $b->{_name_sort_}) or

    ($a->{_disc_max_} <=> $b->{_disc_max_}) or

    ($a->{_disc_no_} <=> $b->{_disc_no_}) or

    ($a->{_attr_status} <=> $b->{_attr_status}) or

    ($a->{trackcount} cmp $b->{trackcount}) or

    ($b->{trmidcount} cmp $a->{trmidcount}) or

    ($b->{puidcount} cmp $a->{puidcount}) or

    ($a->GetId cmp $b->GetId)
};

=head1 AUTHOR

Oliver Charles <oliver.g.charles@googlemail.com>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
