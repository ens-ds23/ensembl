#
# BioPerl module for DBSQL::Obj
#
# Cared for by Ewan Birney <birney@sanger.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::DBSQL::Obj - Object representing an instance of an EnsEMBL DB

=head1 SYNOPSIS

    $db = new Bio::EnsEMBL::DBSQL::Obj( -user => 'root', -db => 'pog' , -host => 'caldy' , -driver => 'mysql' );

    $clone  = $db->get_clone('X45667');

    $contig = $db->get_Contig("dJ52N12.02793");

    $gene   = $db->get_Gene('HG45501');

    

=head1 DESCRIPTION

This object represents a database that is implemented somehow (you shouldn\'t
care much as long as you can get the object). From the object you can pull
out other objects by their stable identifier, such as Clone (accession number),
Exons, Genes and Transcripts. The clone gives you a DB::Clone object, from
which you can pull out associated genes and features. 

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::DBSQL::Obj;

use vars qw(@ISA);
use strict;

# Object preamble - inheriets from Bio::Root::Object

use Bio::Root::Object;

use Bio::EnsEMBL::DB::ObjI;
use Bio::EnsEMBL::DBSQL::Gene_Obj;
use Bio::EnsEMBL::DBSQL::Update_Obj;
use Bio::EnsEMBL::DBSQL::Feature_Obj;
use Bio::EnsEMBL::DBSQL::RawContig;
use Bio::EnsEMBL::DBSQL::Clone;
use Bio::EnsEMBL::FeatureFactory;
use Bio::EnsEMBL::Chromosome;
use DBI;
use Bio::EnsEMBL::DB::ObjI;

use Bio::EnsEMBL::DBSQL::DummyStatement;

@ISA = qw(Bio::EnsEMBL::DB::ObjI Bio::Root::Object);

# _initialize is where the heavy stuff will happen when new is called

sub _initialize {
  my($self,@args) = @_;

  my $make = $self->SUPER::_initialize;

  my ($db,$host,$driver,$user,$password,$debug,$perl,$external) = 
      $self->_rearrange([qw(DBNAME
			    HOST
			    DRIVER
			    USER
			    PASS
			    DEBUG
			    PERLONLYFEATURES
			    EXTERNAL
			    )],@args);

  $db   || $self->throw("Database object must have a database name");
  $user || $self->throw("Database object must have a user");

  #
  # This needs to be rethought. We are caching sequences
  # here to allow multiple exons to be retrieved fine
  # And now more cache's. I think cache's might be a fact of life...
  # 

  $self->{'_contig_seq_cache'} = {};
  $self->{'_contig_seq_cnt'} = 0;
  $self->{'_lock_table_hash'} = {};
  $self->_analysis_cache({});
  $self->{'_external_ff'} = [];

  if( $debug ) {
      $self->_debug($debug);
  } else {
      $self->_debug(0);
  }
  
  if( ! $driver ) {
      $driver = 'mysql';
  }

  if( ! $host ) {
      $host = 'localhost';
  }

  my $dsn = "DBI:$driver:database=$db;host=$host";

  if( $debug && $debug > 10 ) {
      $self->_db_handle("dummy dbh handle in debug mode $debug");
  } else {

      my $dbh = DBI->connect("$dsn","$user",$password, {RaiseError => 1});

      $dbh || $self->throw("Could not connect to database $db user $user using [$dsn] as a locator");
      
      if( $self->_debug > 3 ) {
	  $self->warn("Using connection $dbh");
      }
     
      $self->_db_handle($dbh);
  }

  if ($perl && $perl == 1) {
      $Bio::EnsEMBL::FeatureFactory::USE_PERL_ONLY = 1;
  }

  if( defined $external ){
      foreach my $external_f ( @{$external} ) {
	  $self->add_ExternalFeatureFactory($external_f);
      }
  }


  return $make; # success - we hope!

}

=head2 get_Update_Obj

 Title   : get_Update_Obj
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Update_Obj {
    my ($self) = @_;
    
    my $update_obj = Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
 
    return $update_obj;
}

=head2 write_Clone

 Title   : write_Clone
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub write_Clone {
    my ($self,$clone) = @_;

    my $clone_id = $clone->id;

    $clone || $self->throw("Trying to write a clone without a clone object!\n");
    if( !$clone->isa('Bio::EnsEMBL::DB::CloneI') ) {
	$self->throw("Clone must be a CloneI type, not a $clone");
    }
    
    my @sql;
    
    my $sth = $self->prepare('
        insert into clone (id, version, embl_id, embl_version, htg_phase, created, modified, stored) 
        values(?, ?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), NOW())
        '); 

    my $rv = $sth->execute(
        $clone_id,
        $clone->version || "NULL",
        $clone->embl_id || "NULL",
        $clone->embl_version || "NULL",
        $clone->htg_phase,
        $clone->created,
        $clone->modified
        );
        
    $self->throw("Failed to insert clone $clone_id") unless $rv;

    
    foreach my $contig ( $clone->get_all_Contigs() ) {        
        $self->write_Contig($contig,$clone_id);
    }
    
    foreach my $overlap ($clone->get_all_ContigOverlaps) {    
        $self->write_ContigOverlap($overlap, $clone);
    }
   
}

=head2 write_Contig

 Title   : write_Contig
 Usage   : $obj->write_Contig($contig,$clone)
 Function: Writes a contig and its dna into the database
 Example :
 Returns : 
 Args    :


=cut

sub write_Contig {
    my($self, $contig, $clone)  = @_;
       
     
    $self->throw("$contig is not a Bio::EnsEMBL::DB::ContigI - cannot insert contig for clone $clone")
        unless $contig->isa('Bio::EnsEMBL::DB::ContigI');   
    my $dna = $contig->primary_seq  || $self->throw("No sequence in contig object");
    $dna->id                        || $self->throw("No contig id entered.");
    $clone                          || $self->throw("No clone entered.");
    
#   (defined($contig->species)    && $contig->species   ->isa("Bio::EnsEMBL::Species"))    || $self->throw("No species object defined");
    (defined($contig->chromosome) && $contig->chromosome->isa("Bio::EnsEMBL::Chromosome")) 
                                    || $self->throw("No chromosomeobject defined");
                                    
#   my $species_id    = $self->write_Species   ($contig->species);
#   my $chromosome_id = $self->write_Chromosome($contig->chromosome,$species_id);    
    my $contigid      = $contig->id;
    my $date          = $contig->seq_date;
    my $len           = $dna   ->length;
    my $seqstr        = $dna   ->seq;
    my $offset        = $contig->embl_offset();
    my $order         = $contig->embl_order();
    my $chromosome_id = $contig->chromosome->get_db_id;
    
    # Insert the sequence into the dna table
    $self->_insertSequence($seqstr, $date);
    
    my @sql;
    
    my $sth = $self->prepare("
        insert into contig(id, internal_id, dna, length, clone, offset, corder, chromosomeId ) 
        values(?, ?, LAST_INSERT_ID(), ?, ?, ?, ?, ?)
        "); 
        
    my $rv = $sth->execute(
        $contigid,
        'null',
        $len,
        $clone,
        $offset,
        $order,
        $chromosome_id    
        );  
          
    $self->throw("Failed to insert contig $contigid") unless $rv;
       
    
    $sth = $self->prepare("select last_insert_id()");
    my $res = $sth->execute;
    my $row = $sth->fetchrow_hashref;
    
    my $id  = $row->{'last_insert_id()'};
    
    print(STDERR "Contig $contigid - $id\n");
    
    $contig->internal_id($id);
    
    # write sequence features. We write all of them together as it
    # is more efficient
    my @features = $contig->get_all_SeqFeatures;
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    $feature_obj->write($contig, @features);
    
    return 1;
}

=head2 _insertSequence

 Title   : _insertSequence
 Usage   : $obj->_insertSequence
 Function: Insert the dna sequence and date into the dna table.
 Example :
 Returns : 
 Args    : $sequence, $date


=cut

sub _insertSequence {
    my ($self, $sequence, $date) = @_;
    
    $sequence =~ tr/atgcn/ATGCN/;
    
    my $statement = $self->prepare("
        insert into dna(sequence,created) 
        values(?, FROM_UNIXTIME(?))
        "); 
        
    my $rv = $statement->execute($sequence, $date); 
    
    $self->throw("Failed to insert dna $sequence") unless $rv;    
}


=head2 write_Chromosome

 Title   : write_Chromosome
 Usage   : $obj->write_Chromosome
 Function: writes a chromosome into the database
 Example :
 Returns : 
 Args    :


=cut

sub write_Chromosome {
    my ($self,$chromosome,$species_id) = @_;

    $self->throw("No chromosome argument input") unless defined($chromosome);
    $self->throw("No species_id argument input") unless defined($species_id);

    if (!$chromosome->isa("Bio::EnsEMBL::Chromosome")) {
	$self->throw("[$chromosome] is not a Bio::EnsEMBL::Chromosome object");
    }

    my $query = "select chromosome_id " .
	        "from   chromosome " .
		"where  name       = '" . $chromosome->name . "' " .
		"and    species_id = "  . $species_id . 
		"and    id         = "  . $chromosome->id;

    my $sth = $self->prepare($query);
    my $res = $sth->execute;

    if ($sth->rows == 1) {
	my $rowhash       = $sth->fetchrow_hashref;
	my $chromosome_id = $rowhash->{chromosome_id};
	return $chromosome_id;
    } 

    $query =  "insert into chromosome(chromosome_id,name,id,species_id) " . 
	      "            values(null,'" . $chromosome->name . "'," . $chromosome->id . "," . $species_id . ")";
	
    
    $sth = $self->prepare($query);
    $res = $sth->execute;

    $sth = $self->prepare("select last_insert_id()");
    $res = $sth->execute;

    my $rowhash       = $sth->fetchrow_hashref;
    my $chromosome_id = $rowhash->{'last_insert_id()'};
   
    return $chromosome_id;
}


=head2 write_Species

 Title   : write_Species
 Usage   : $obj->write_Species
 Function: writes a species object into the database
 Example :
 Returns : 
 Args    :


=cut

sub write_Species {
    my ($self,$species) = @_;

    if (!defined($species)) {
	$self->throw("No species argument input");
    }
    if (!$species->isa("Bio::EnsEMBL::Species")) {
	$self->throw("[$species] is not a Bio::EnsEMBL::Species object");
    }

    my $query = "select species_id " .
	        "from   species " .
		"where  nickname    = '" . $species->nickname . "' " . 
		"and    taxonomy_id = "  . $species->taxonomy_id;

    my $sth = $self->prepare($query);
    my $res = $sth->execute;

    if ($sth->rows == 1) {
	my $rowhash    = $sth->fetchrow_hashref;
	my $species_id = $rowhash->{species_id};
	return $species_id;
    } 

    $query =  "insert into species(species_id,nickname,taxonomy_id) " . 
	      "            values(null,'" . $species->nickname . "'," . $species->taxonomy_id . ")";
	
    
    $sth = $self->prepare($query);
    $res = $sth->execute;

    $sth = $self->prepare("select last_insert_id()");
    $res = $sth->execute;

    my $rowhash = $sth->fetchrow_hashref;
    my $species_id = $rowhash->{'last_insert_id()'};
   
    return $species_id;
}

=head2 write_ContigOverlap

 Title   : write_ContigOverlap
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub write_ContigOverlap {
    my ($self, $overlap, $clone) = @_;

    if (!defined($overlap)) {
	$self->throw("No overlap object");
    }

    if (!($overlap->isa("Bio::EnsEMBL::ContigOverlap"))) {
	$self->throw("[$overlap] is not a Bio::EnsEMBL::ContigOverlap");
    }

    my $contiga           = $overlap->contiga;
    my $contigb           = $overlap->contigb;
    my $contig_a_position = $overlap->positiona;
    my $contig_b_position = $overlap->positionb;
    my $overlap_type      = $overlap->overlap_type;

    # Firstly check that both contigs involved in the overlap are present in the db.
    # If they are new they may not have been inserted yet. In this case when they are inserted, 
    # this ContigOverlap should be found again and will be correctly inserted, hopefully!
    my $sth = $self->prepare("select id from contig where id = '". $contiga->id ."'");
    my $res = $sth->execute;
    if ($sth->rows == 0) {
        # Contig a has not been entered into the DB yet! 
        $self->warn("ContigOverlap of " . $clone->id . " can't be written as contiga: " . 
            $contiga->id . " not found in DB");
	return;
    } 
    
    $sth = $self->prepare("select id from contig where id = '". $contigb->id ."'");
    $res = $sth->execute;
    if ($sth->rows == 0) {
        # Contig b has not been entered into the DB yet! 
        $self->warn("ContigOverlap of " . $clone->id . " can't be written as contigb: " . 
            $contigb->id . " not found in DB");
	return;
    }
    
    print(STDERR "contiga "         . $contiga->id . "\t" . $contiga->internal_id . "\n");
    print(STDERR "contigb "         . $contigb->id . "\t" . $contigb->internal_id . "\n");
    print(STDERR "contigaposition " . $contig_a_position . "\n");
    print(STDERR "contigbposition " . $contig_b_position . "\n");
    print(STDERR "overlap type "    . $overlap_type . "\n");

    # First of all we need to fetch the dna ids
    my $query = "select d.id from dna as d,contig as c " .
	        "where  d.id = c.dna ".
  	        "and    c.id = '". $contiga->id ."'";

    $sth = $self->prepare($query);
    $res = $sth->execute;
    my $rowhash;
    my $dna_a_id;
    my $dna_b_id;
    
    if ($sth->rows == 0) {
        $self->throw("No dna entry found for " . $contiga->id);
    }
    elsif ($sth->rows > 1) {
        $self->throw("More than one dna entry found for " . $contiga->id);
    }
    else {
        $rowhash = $sth->fetchrow_hashref;
        $dna_a_id = $rowhash->{id};
    }    

    $query = "select d.id from dna as d,contig as c " .
	        "where  d.id = c.dna ".
  	        "and    c.id = '". $contigb->id ."'";
    $sth = $self->prepare($query);
    $res = $sth->execute; 
     
    if ($sth->rows == 0) {
        $self->throw("No dna entry found for " . $contigb->id);
    }
    elsif ($sth->rows > 1) {
        $self->throw("More than one dna entry found for " . $contigb->id);
    }
    else {
        $rowhash = $sth->fetchrow_hashref;
        $dna_b_id = $rowhash->{id};
    }  
       

    my $type     = $overlap->source;
    my $distance = $overlap->distance;

    print(STDERR "DNA ids are $dna_a_id : $dna_b_id\n");

    $self->throw("DNA ids are the same [$dna_a_id][$dna_b_id]") if ($dna_a_id == $dna_b_id);
    # First check this overlap doesn't already exist.
    
    $query = "select * from  contigoverlap " .
	     "where  (dna_a_id = $dna_a_id and  dna_b_id = $dna_b_id) " .
	     "or     (dna_a_id = $dna_b_id and  dna_b_id = $dna_a_id) ";

    $sth   = $self->prepare($query);
    $res   = $sth->execute;

    if ($sth->rows > 0) {
	$self->warn("ContigOverlap between $dna_a_id and $dna_b_id exists. Not writing");
	return;
    }

    $query = "insert into contigoverlap(dna_a_id," .
	                                "dna_b_id," .
	                                "contig_a_position," .
					"contig_b_position,".
					"type,".
					"overlap_size,".
					"overlap_type) " .
				"values($dna_a_id," .
				       "$dna_b_id," . 
				       "$contig_a_position," .
				       "$contig_b_position,".
				       "'$type'," .
				       "$distance," .
				       "'$overlap_type')";

    print(STDERR "query is $query\n");

    $sth = $self->prepare($query);
    $res = $sth ->execute;

}

=head2 prepare

 Title   : prepare
 Usage   : $sth = $dbobj->prepare("select seq_start,seq_end from feature where analysis = \" \" ");
 Function: prepares a SQL statement on the DBI handle

           If the debug level is greater than 10, provides information into the
           DummyStatement object
 Example :
 Returns : A DBI statement handle object
 Args    : a SQL string


=cut

sub prepare {
   my ($self,$string) = @_;

   if( ! $string ) {
       $self->throw("Attempting to prepare an empty SQL query!");
   }
   if( !defined $self->_db_handle ) {
      $self->throw("Database object has lost its database handle! getting otta here!");
   }
      

   if( $self->_debug > 10 ) {
       print STDERR "Prepared statement $string\n";
       my $st = Bio::EnsEMBL::DBSQL::DummyStatement->new();
       $st->_fileh(\*STDERR);
       $st->_statement($string);
       return $st;
   }

   # should we try to verify the string?

   return $self->_db_handle->prepare($string);
}


=head2 add_ExternalFeatureFactory

 Title   : add_ExternalFeatureFactory
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub add_ExternalFeatureFactory{
   my ($self,$value) = @_;

   unless( ref $value && $value->isa('Bio::EnsEMBL::DB::ExternalFeatureFactoryI') ) {
       $self->throw("[$value] is not a Bio::EnsEMBL::DB::ExternalFeatureFactoryI but it should be!");
   }

   push(@{$self->{'_external_ff'}},$value);
}

=head2 _each_ExternalFeatureFactory

 Title   : _each_ExternalFeatureFactory
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub _each_ExternalFeatureFactory{
   my ($self) = @_;

   return @{$self->{'_external_ff'}}
}


=head2 _analysis_cache

 Title   : _analysis_cache
 Usage   : $obj->_analysis_cache()
 Function: 
 Returns : reference to a hash
 Args    : newvalue (optional)


=cut

sub _analysis_cache{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'_analysis_cache'} = $value;
    }
    return $obj->{'_analysis_cache'};

}

=head2 _contig_seq_cache

 Title   : _contig_seq_cache
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub _contig_seq_cache{
   my ($self,$id,$seq) = @_;

   if( $seq ) {
       
       #
       # Every 100 hits, flush the cache
       #
       if( $self->{'_contig_seq_cnt'} > 100 ) {
	   $self->_flush_seq_cache;
	   $self->{'_contig_seq_cnt'} = 0;
       }

       $self->{'_contig_seq_cnt'}++;
       $self->{'_contig_seq_cache'}->{$id} = $seq;
   }

   return $self->{'_contig_seq_cache'}->{$id};
}

=head2 _flush_seq_cache

 Title   : _flush_seq_cache
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub _flush_seq_cache{
   my ($self,@args) = @_;

   $self->{'_contig_seq_cache'} = {};

}

=head2 _debug

 Title   : _debug
 Usage   : $obj->_debug($newval)
 Function: 
 Example : 
 Returns : value of _debug
 Args    : newvalue (optional)


=cut

sub _debug{
    my ($self,$value) = @_;
    if( defined $value) {
	$self->{'_debug'} = $value;
    }
    return $self->{'_debug'};
    
}


=head2 _db_handle

 Title   : _db_handle
 Usage   : $obj->_db_handle($newval)
 Function: 
 Example : 
 Returns : value of _db_handle
 Args    : newvalue (optional)


=cut

sub _db_handle{
   my ($self,$value) = @_;
   if( defined $value) {
      $self->{'_db_handle'} = $value;
    }
    return $self->{'_db_handle'};

}

=head2 _lock_tables

 Title   : _lock_tables
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub _lock_tables{
   my ($self,@tables) = @_;
   
   my $state;
   foreach my $table ( @tables ) {
       if( $self->{'_lock_table_hash'}->{$table} == 1 ) {
	   $self->warn("$table already locked. Relock request ignored");
       } else {
	   if( $state ) { $state .= ","; } 
	   $state .= "$table write";
	   $self->{'_lock_table_hash'}->{$table} = 1;
       }
   }

   my $sth = $self->prepare("lock tables $state");
   my $rv = $sth->execute();
   $self->throw("Failed to lock tables $state") unless $rv;

}

=head2 _unlock_tables

 Title   : _unlock_tables
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub _unlock_tables{
   my ($self,@tables) = @_;

   my $sth = $self->prepare("unlock tables");
   my $rv  = $sth->execute();
   $self->throw("Failed to unlock tables") unless $rv;
   %{$self->{'_lock_table_hash'}} = ();
}


=head2 DESTROY

 Title   : DESTROY
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub DESTROY{
   my ($obj) = @_;

   $obj->_unlock_tables();

   if( $obj->{'_db_handle'} ) {
       $obj->{'_db_handle'}->disconnect;
       $obj->{'_db_handle'} = undef;
   }
}

##################DEPRECATED METHODS######################
#                                                        #
#All the methods below are deprecated methods,           #
#only kept here to allow old scripts to work             #
#They all send a warning and call the new method instead #
#                                                        #
##########################################################

=head2 get_Gene

 Title   : get_Gene
 Usage   : $obj->get_Gene($geneid, $supporting)
 Function: gets one gene out of the db with or without supporting evidence
 Example : $obj->get_Gene('ENSG00000009151','evidence')
 Returns : gene object (with transcripts, exons and supp.evidence if wanted)
 Args    : gene id and supporting tag (if latter not specified, assumes without
	   Note that it is much faster to get genes without supp.evidence!


=cut

sub get_Gene {
   my ($self,$geneid, $supporting) = @_;

   $self->warn("Obj->get_Gene is a deprecated method! 
Calling Gene_Obj->get instead!");

   return $self->gene_Obj->get($geneid,$supporting);
}

=head2 get_Gene_array

 Title   : get_Gene_array
 Usage   :
 Function: old deprecated method, points to new method
           get_gene_array_supporting without asking for supp.evidence
 Example :
 Returns : 
 Args    :


=cut

sub get_Gene_array {
    my ($self,@geneid) = @_;

    $self->throw("Very deprecated method, should call methods with supporting evidence and from
Gene_Obj!");
}

=head2 get_Gene_array_supporting

 Title   : get_Gene_array_supporting
 Usage   : $obj->get_Gene_array_supporting($supporting,@geneid)
 Function: Gets an array of genes, with transcripts and exons. If $supporting
           equal to 'evidence' the supporting evidence for each exon is also read
           from the supporting evidence table
 Example : $obj->get_Gene_array_supporting ('evidence',@geneid)
 Returns : an array of gene objects
 Args    : 'evidence' and gene id array

=cut

sub get_Gene_array_supporting {
    my ($self,$supporting,@geneid) = @_;

    $self->warn("Obj->get_Gene_array_supporting is a deprecated method!
Calling Gene_Obj->get_array_supporting instead!");

    return $self->gene_Obj->get_array_supporting($supporting,@geneid);
}

=head2 donor_locator
    
 Title   : get_donor_locator
 Usage   : $obj->get_donor_locator; 
 Function: Reads the meta table of the database to get the donor_database_locator
 Example : get_donor_locator
 Returns : locator string
 Args    : none


=cut

sub get_donor_locator {
    my ($self) = @_;

    $self->warn("Obj->get_donor_locator is a deprecated method! 
Calling Update_Obj->get_donor_locator instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_donor_locator();
}

=head2 get_last_update_offset

 Title   : get_last_update_offset
 Usage   : $obj->get_last_update_offset; 
 Function: Reads the meta table of the database to get the last_update time - offset time
 Example : get_last_update_offset
 Returns : UNIX TIME of last update - offset time
 Args    : none

=cut

sub get_last_update_offset{
    my ($self) = @_;

    $self->warn("Obj->get_last_update_offset is a deprecated method! 
Calling Update_Obj->get_last_update_offset instead!");
 
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_last_update_offset();
}    

=head2 get_last_update

 Title   : get_last_update
 Usage   : $obj->get_last_update; 
 Function: Reads the db_update table of the database to get the finishing time of the
           last complete update
 Example : get_last_update
 Returns : UNIX TIME of last update
 Args    : none

=cut

sub get_last_update{
    my ($self) = @_;
    
    $self->warn("Obj->get_last_update is a deprecated method! 
Calling Update_Obj->get_last_update_offset instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_last_update_offset();
}     

=head2 get_now_offset

 Title   : get_now_offset
 Usage   : $obj->get_now_minus_offset; 
 Function: Gets the current time from the point of view of the database, substracts the
           offset time found in the meta table and gives back unix time of now-offset
 Example : get_now_offset
 Returns : UNIX TIME of now - offset_time
 Args    : none


=cut

sub get_now_offset{
    my ($self) = @_;

    $self->warn("Obj->get_now_offset is a deprecated method! 
Calling Update_Obj->get_now_offset instead!");
   
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_now_offset();
}
    
=head2 get_offset

 Title   : get_offset
 Usage   : $obj->get_offset; 
 Function: Gets the offset time found in the meta table
 Example : get_offset
 Returns : UNIX TIME of offset_time
 Args    : none


=cut

sub get_offset{
    my ($self) = @_;

    $self->throw("Obj->get_offset should not be needed any more!"); 
}
    
=head2 get_Protein_annseq

 Title   : get_Protein_annseq
 Usage   : get_Protein_annseq ($ENSP); 
 Function: Creates an annseq object for a particular peptide, storing the peptide
           sequence in $annseq->primary_seq, and adding all the protein features as generic
           Seqfeatures
 Example : 
 Returns : $annseq
 Args    : $ENSP


=cut

sub get_Protein_annseq{
    my ($self,$ENSP) = @_;

    $self->warn("Obj->get_Protein_annseq is a deprecated method! 
Calling Feature_Obj->get_Protein_annseq instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->get_Protein_annseq($ENSP);
} 

=head2 get_Transcript
    
 Title   : get_Transcript
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut
    
sub get_Transcript{
    my ($self,$transid) = @_;
 
    $self->warn("Obj->get_Transcript is a deprecated method! 
Calling Gene_Obj->get_Translation instead!");

    return $self->gene_Obj->get_Transcript($transid);
}

=head2 get_Translation

 Title   : get_Translation
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Translation{
   my ($self,$translation_id) = @_;

   $self->warn("Obj->get_Translation is a deprecated method! 
Calling Gene_Obj->get_Translation instead!");

   return $self->gene_Obj->get_Translation($translation_id);
}

=head2 get_Exon

 Title   : get_Exon
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Exon{
   my ($self,$exonid) = @_;

   $self->warn("Obj->get_Exon is a deprecated method! 
Calling Gene_Obj->get_Exon instead!");

   return $self->gene_Obj->get_Exon($exonid);
}

=head2 get_all_Gene_id

 Title   : get_all_Gene_id
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_all_Gene_id{
   my ($self) = @_;

   $self->warn("Obj->get_all_Gene_id is a deprecated method! 
Calling Gene_Obj->get_all_Gene_id instead!");

   return $self->gene_Obj->get_all_Gene_id();
}

=head2 get_updated_Clone_id
    
 Title   : get_updated_Clone_id
 Usage   : $obj->get_updated_Clone_id ($recipient_last_update, $recipient_now)
 Function: Gets all the objects that have been updated (i.e.change in 
 Example : $obj->get_updated_Objects (973036800,973090800)
 Returns : database objects (clones and genes)
 Args    : $recipient_last_update, $recipient_now

=cut

sub get_updated_Clone_id {
    my ($self, $last_offset, $now_offset) = @_;
    
    $self->warn("Obj->get_updated_Clone_id is a deprecated method! 
Calling Update_Obj->get_updated_Clone_id instead!");
   
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_updated_Clone_id($last_offset, $now_offset);
}
    

=head2 get_updated_Objects
    
 Title   : get_updated_Objects
 Usage   : $obj->get_updated_Objects ($recipient_last_update, $recipient_now)
 Function: Gets all the objects that have been updated (i.e.change in 
	   version number) between the current time - offset time given by
           the recipient database and the last update time stored in its meta table 
 Example : $obj->get_updated_Objects (973036800,973090800)
 Returns : database objects (clones and genes)
 Args    : $recipient_last_update, $recipient_now

=cut

sub get_updated_Objects{
    my ($self, $last_offset, $now_offset) = @_;

    $self->warn("Obj->get_updated_Objects is a deprecated method! 
Calling Update_Obj->get_updated_Objects instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_updated_Objects($last_offset,$now_offset);
}
    

=head2 get_updated_Ghosts
    
 Title   : get_updated_Ghosts
 Usage   : $obj->get_updated_Ghosts ($recipient_last_update, $recipient_now_offset)
 Function: Gets all the ghosts for objects that have been deleted (i.e.permanently from 
	   the donor db) between the current time - offset time given by
           the recipient database and the last update time stored in its meta table 
 Example : $obj->get_updated_Ghosts (973036800,973090800)
 Returns : ghost objects
 Args    : $recipient_last_update, $recipient_now_offset

=cut

sub get_updated_Ghosts{
    my ($self, $last_offset, $now_offset) = @_;

    $self->warn("Obj->get_updated_Ghosts is a deprecated method! 
Calling Update_Obj->get_updated_Ghosts instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_updated_Ghosts($last_offset, $now_offset);
}
    
=head2 get_Ghost
    
 Title   : get_Ghost
 Usage   : $obj->get_Ghost ($ghost_id,$ghost_version,$ghost_obj_type)
 Function: Gets a ghost by id, version,obj_type  
 Example : $obj->get_Ghost ('test','1','transcript')
 Returns : ghost objects
 Args    : ghost id, version and object type

=cut

sub get_Ghost{
    my ($self, $ghost_id, $ghost_type) = @_;

    $self->warn("Obj->get_Ghost is a deprecated method! 
Calling Update_Obj->get_Ghost instead!");
   
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->get_Ghost($ghost_id,$ghost_type);
}
    

=head2 write_Ghost
    
 Title   : write_Ghost
 Usage   : $obj->write_Ghost ($ghost)
 Function: Writes a ghost to the database  
 Example : $obj->write_Ghost ($ghost)
 Returns : 
 Args    : ghost object

=cut

sub write_Ghost{
    my ($self, $ghost) = @_;

    $self->warn("Obj->write_Ghost is a deprecated method! 
Calling Update_Obj->write_Ghost instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->write_Ghost($ghost);
}
    

=head2 archive_Gene
    
 Title   : archive_Gene
 Usage   : $obj->archive_gene($gene,$arcdb)
 Function: Deletes a gene and all its transcripts and exons, 
           and archives partial info in the archive db passed on.
 Example : 
 Returns : nothing
 Args    : $gene, $arcdb (archive database object)


=cut

sub archive_Gene {
   my ($self,$gene,$arc_db) = @_;

   $self->warn("Obj->archive_Gene is a deprecated method! 
Calling Update_Obj->archive_Gene instead!");
   
   my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
   return $update_obj->archive_Gene($gene,$arc_db);
}

=head2 delete_Exon

 Title   : delete_Exon
 Usage   : $obj->delete_Exon($exon_id)
 Function: Deletes exon, including exon_transcript rows
 Example : $obj->delete_Exon(ENSE000034)
 Returns : nothing
 Args    : $exon_id


=cut

sub delete_Exon{
    my ($self,$exon_id) = @_;

    $self->warn("Obj->delete_Exon is a deprecated method
Calling Gene_Obj->delete_Exon instead!");

    return $self->gene_Obj->delete_Exon($exon_id);
}

=head2 delete_Supporting_Evidence

 Title   : delete_Supporting_Evidence
 Usage   : $obj->delete_Supporting_Evidence($exon_id)
 Function: Deletes exon\'s supporting evidence entries
 Example : $obj->delete_Supporting_Evidence(ENSE000034)
 Returns : nothing
 Args    : $exon_id


=cut

sub delete_Supporting_Evidence {
    my ($self,$exon_id) = @_;
 
    $self->warn("Obj->delete_Supporting_Evidence is a deprecated method
Calling Gene_Obj->delete_Supporting_Evidence instead!");

    return $self->gene_Obj->delete_Supporting_Evidence($exon_id);
}

=head2 delete_Features

 Title   : delete_Features
 Usage   :
 Function: deletes all features from a contig;
 Example :
 Returns : 
 Args    :


=cut

sub delete_Features {
    my ($self,$contig) = @_;

    $self->warn("Obj->delete_Features is a deprecated method! 
Calling Feature_Obj->delete instead!");

   my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
   return $feature_obj->delete($contig);
} 

=head2 delete_Gene

 Title   : delete_Gene
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub delete_Gene{
   my ($self,$geneid) = @_;

   $self->warn("Obj->delete_Gene is a deprecated method! 
Calling Gene_Obj->delete instead!");

   return $self->gene_Obj->delete($geneid);
}

=head2 geneid_to_cloneid

 Title   : geneid_to_cloneid
 Usage   : @cloneid = $db->geneid_to_cloneid($geneid);
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub geneid_to_cloneid{
    my ($self,$geneid) = @_;
    
    $self->warn("Obj->geneid_to_cloneid is a deprecated method, called Gene_Obj->each_cloneid instead!
All the gene, transcript, and exon methods are now to be found in Gene_Obj");
    return $self->gene_Obj->each_cloneid($geneid);
}

=head2 replace_last_update
    
 Title   : replace_last_update(@$now_offset)
 Usage   : $obj->replace_last_update($now_offset)
 Function: Replaces the time in the last update field of the meta table with the now_offset time of the recipient
 Example : 
 Returns : nothing
 Args    : 

=cut

sub replace_last_update {
    my ($self, $now_offset) = @_;

    $self->warn("Obj->replace_last_update is a deprecated method! 
Calling Update_Obj->replace_last_update instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->replace_last_update($now_offset);
}        

=head2 current_update
    
 Title   : current_update
 Usage   : $obj->current_update
 Function: Checks whether the database is in the middle of an update
 Example : 
 Returns : 0,1
 Args    : 

=cut

sub current_update {
    my ($self) = @_;

     $self->warn("Obj->current_update is a deprecated method! 
Calling Update_Obj->current_update instead!");
 
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->current_update();
}    

=head2 start_update
    
 Title   : start_update
 Usage   : my $id = $obj->start_update
 Function: Enters a new updating process in the db_update table
 Example : 
 Returns : int
 Args    : 

=cut

sub start_update {
    my ($self,$start,$end) = @_;
    
     $self->warn("Obj->start_update is a deprecated method! 
Calling Update_Obj->start_update instead!");
 
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->start_update($start,$end);
}   

=head2 finish_update
    
 Title   : finish_update
 Usage   : my $id = $obj->finish_update
 Function: Completes the current update process
 Example : 
 Returns : nothing
 Args    : None

=cut

sub finish_update {
    my ($self) = @_;

    $self->warn("Obj->finish_update is a deprecated method! 
Calling Update_Obj->finish_update instead!");
    
    my $update_obj=Bio::EnsEMBL::DBSQL::Update_Obj->new($self);
    return $update_obj->finish_update();
}   

=head2 write_Gene

 Title   : write_Gene
 Usage   : $obj->write_Gene($gene)
 Function: writes a particular gene into the database
           
 Example :
 Returns : 
 Args    :


=cut


sub write_Gene{
   my ($self,$gene) = @_;

   $self->warn("Obj->write_Gene is a deprecated method! 
Calling Gene_Obj->write instead!");

   return $self->gene_Obj->write($gene);
}

=head2 write_all_Protein_features

 Title   : write_all_Protein_features
 Usage   : $obj->write_all_Protein_features($ENSP)
 Function: writes all protein features of a particular peptide into the database          
 Example :
 Returns : 
 Args    :


=cut

sub write_all_Protein_features {
    my ($self,$prot_annseq,$ENSP) = @_;

    $self->warn("Obj->write_all_Protein_features is a deprecated method! 
Calling Feature_Obj->write_all_Protein_features instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->write_all_Protein_features($prot_annseq,$ENSP);
} 


=head2 write_Protein_feature

 Title   : write_Protein_feature
 Usage   : $obj->write_Protein_feature($ENSP, $feature)
 Function: writes a protein feature object of a particular peptide into the database          
 Example :
 Returns : 
 Args    :


=cut

sub write_Protein_feature {
    my ($self,$ENSP,$feature) = @_;
 
    $self->warn("Obj->write_Protein_feature is a deprecated method! 
Calling Feature_Obj->write_Protein_feature instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->write_Protein_feature($ENSP,$feature);
} 

=head2 write_Feature

 Title   : write_Feature
 Usage   : $obj->write_Feature($contig,@features)
 Function: Writes a feature on the genomic sequence of a contig into the database
 Example :
 Returns : nothing
 Args    : Bio::EnsEMBL::SeqFeatureI


=cut

sub write_Feature {
    my ($self,$contig,@features) = @_;

    $self->warn("Obj->write_Feature is a deprecated method! 
Calling Feature_Obj->write_Feature instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->write($contig,@features);
} 

=head2 write_supporting_evidence

 Title   : write_supporting_evidence
 Usage   : $obj->write_supporting_evidence
 Function: Writes supporting evidence features to the database
 Example :
 Returns : nothing
 Args    : None


=cut

sub write_supporting_evidence {
    my ($self,$exon) = @_;

    $self->warn("Obj->write_supporting_evidence is a deprecated method!
Calling Gene_Obj->write_supporting_evidence instead!");

    return $self->gene_Obj->write_supporting_evidence($exon);
}

=head2 get_supporting_evidence

 Title   : get_supporting_evidence
 Usage   : $obj->get_supporting_evidence
 Function: Writes supporting evidence features to the database
 Example :
 Returns : nothing
 Args    : array of exon objects, needed to know which exon to attach the evidence to


=cut

sub get_supporting_evidence {
    my ($self,@exons) = @_;

    $self->warn("Obj->get_supporting_evidence is a deprecated method! 
Calling Gene_Obj->get_supporting_evidence instead!");

   return $self->gene_Obj->get_supporting_evidence(@exons);
}

=head2 write_Analysis

 Title   : write_Analysis
 Usage   : $obj->write_Analysis($anal)
 Function: Writes analysis details to the database
           Checks first whether this analysis entry already exists
 Example :
 Returns : int
 Args    : Bio::EnsEMBL::AnalysisI


=cut

sub write_Analysis {
    my ($self,$analysis) = @_;

    $self->warn("Obj->write_Analysis is a deprecated method! 
Calling Feature_Obj->write_Analysis instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->write_Analysis($analysis);
} 
    
=head2 exists_Homol_Feature

 Title   : exists_Homol_Feature
 Usage   : $obj->exists_Homol_Feature($feature)
 Function: Tests whether this feature already exists in the database
 Example :
 Returns : nothing
 Args    : Bio::SeqFeature::Homol


=cut

sub exists_Homol_Feature {
    my ($self,$feature,$analysisid,$contig) = @_;

    $self->warn("Obj->exists_Homol_Feature is a deprecated method! 
Calling Feature_Obj->exists_Homol_Feature instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->exists($feature,$analysisid,$contig);
} 
    
=head2 get_Analysis

 Title   : get_Analysis
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Analysis {
    my ($self,$id) = @_;

    $self->warn("Obj->get_Analysis is a deprecated method! 
Calling Feature_Obj->get_Analysis instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->get_Analysis($id);
} 

=head2 exists_Analysis

 Title   : exists_Analysis
 Usage   : $obj->exists_Analysis($anal)
 Function: Tests whether this feature already exists in the database
 Example :
 Returns : Analysis id if the entry exists
 Args    : Bio::EnsEMBL::Analysis


=cut

sub exists_Analysis {
    my ($self,$analysis) = @_;
    
    $self->warn("Obj->exists_Analysis is a deprecated method! 
Calling Feature_Obj->exists_Analysis instead!");
    
    my $feature_obj=Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);
    return $feature_obj->exists_Analysis($analysis);
} 
 
    
=head2 write_Transcript

 Title   : write_Transcript
 Usage   : $obj->write_Transcript($trans,$gene)
 Function: writes a particular transcript *but not the exons* into
           the database
 Example :
 Returns : 
 Args    :


=cut

sub write_Transcript{
   my ($self,$trans,$gene) = @_;

   $self->warn("Obj->write_Transcript is a deprecated method! 
Calling Gene_Obj->write_Transcript instead!");

   return $self->gene_Obj->write_Transcript($trans,$gene);
}

=head2 write_Translation

 Title   : write_Translation
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub write_Translation{
    my ($self,$translation) = @_;

    $self->warn("Obj->write_Translation is a deprecated method
Calling Gene_Obj->write_Translation instead!");

    return $self->gene_Obj->write_Translation($translation);
}


=head2 write_Exon

 Title   : write_Exon
 Usage   : $obj->write_Exon($exon)
 Function: writes a particular exon into the database
 Example :
 Returns : 
 Args    :


=cut

sub write_Exon {
   my ($self,$exon) = @_;

   $self->warn("Obj->write_Exon is a deprecated method! 
Calling Gene_Obj->write_Exon instead!");

   return $self->gene_Obj->write_Exon($exon);
}

=head2 get_Clone

 Title   : get_Clone
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Clone { 
    my ($self,$id) = @_;
    
    #No warning shown for the time being...
   #$self->warn("Obj->get_Clone is a deprecated method! 
#Calling Clone->fetch instead!");
    
    my $clone = new Bio::EnsEMBL::DBSQL::Clone( -id    => $id,
						-dbobj => $self );
   
    return $clone->fetch();
}
  
=head2 get_Contig

 Title   : get_Contig
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Contig{
   my ($self,$id) = @_;

   #$self->warn("Obj->get_Contig is a deprecated method! 
#Calling Contig->fetch instead!");

   my $contig      = new Bio::EnsEMBL::DBSQL::RawContig ( -dbobj => $self,
							  -id    => $id );
   
   return $contig->fetch();
}

=head2 get_Contigs_by_Chromosome

 Title   : get_Contig_by_Chromosome
 Usage   : @contigs = $dbobj->get_Contig_by_Chromosome( $chrObj );
 Function: retrieve contigs belonging to a certain chromosome from the
           database 
 Example :
 Returns : A list of Contig objects. Probably an empty list.
 Args    :


=cut

sub get_Contigs_by_Chromosome {
    my ($self,$chromosome ) = @_;
    
    $self->warn("Obj->get_Contigs_by_Chromosome is a deprecated method! 
Calling Contig->get_by_Chromosome instead!");

    my $contig = new Bio::EnsEMBL::DBSQL::RawContig 
	( -dbobj => $self,		
	 -id    => 'temp');
    
    return $contig->get_by_Chromosome;
}

=head2 get_all_Clone_id

 Title   : get_all_Clone_id
 Usage   : @cloneid = $obj->get_all_Clone_id
 Function: returns all the valid (live) Clone ids in the database
 Example :
 Returns : 
 Args    :


=cut

sub get_all_Clone_id{
   my ($self) = @_;

   $self->warn("Obj->delete_Clone is a deprecated method! 
Calling Clone->delete instead!");
   
   my $clone = new Bio::EnsEMBL::DBSQL::Clone( -id    => 'temp',
					       -dbobj => $self );
   
   return $clone->get_all_id();
}


=head2 delete_Clone

 Title   : delete_Clone
 Usage   : $obj->delete_Clone($clone_id)
 Function: Deletes clone, including contigs, but not its genes
 Example :
 Returns : 
 Args    :


=cut

sub delete_Clone{
   my ($self,$clone_id) = @_;

   $self->warn("Obj->delete_Clone is a deprecated method! 
Calling Clone->delete instead!");
   
   (ref($clone_id)) && $self->throw ("Passing an object reference instead of a variable\n");

   my $clone = new Bio::EnsEMBL::DBSQL::Clone( -id    => $clone_id,
					       -dbobj => $self );
   
   return $clone->delete();
}

=head2 cloneid_to_geneid

 Title   : cloneid_to_geneid
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub cloneid_to_geneid{
   my ($self,$cloneid) = @_;

    $self->warn("Obj->cloneid_to_geneid is a deprecated method! 
Calling Clone->get_all_geneid instead!");

   (ref($cloneid)) && $self->throw ("Passing an object reference instead of a variable!\n");

   my $clone = new Bio::EnsEMBL::DBSQL::Clone( -id    => $cloneid,
					       -dbobj => $self );
   
   return $clone->get_all_my_geneid();
}


=head2 gene_Obj
    
 Title   : gene_Obj
 Usage   : my $geneobj = $db->gene_Obj
 Function: Returns the gene object database handle
 Example : 
 Returns : Bio::EnsEMBL::DB::Gene_ObjI
 Args    : 

=cut

sub gene_Obj {
    my ($self) = @_;

    unless (defined($self->{_gene_obj})) {
	$self->{_gene_obj} = Bio::EnsEMBL::DBSQL::Gene_Obj->new($self);    
    }

    return $self->{_gene_obj};

}

=head2 feature_Obj
    
 Title   : feature_Obj
 Usage   : my $featureobj = $db->feature_Obj
 Function: Returns the feature object database handle
 Example : 
 Returns : Bio::EnsEMBL::DB::Feature_ObjI
 Args    : 

=cut

sub feature_Obj {
    my ($self) = @_;

    unless (defined($self->{_feature_obj})) {
	$self->{_feature_obj} = Bio::EnsEMBL::DBSQL::Feature_Obj->new($self);    
    }

    return $self->{_feature_obj};

}


=head2 find_GenomeHits
    
 Title   : find_GenomeHits
 Usage   : my @features = $self->find_GenomeHits($hid)
 Function: Finds all features in the db that
           are hits to a sequence with id $hid
 Example : 
 Returns : @ Bio::EnsEMBL::FeaturePair
 Args    : string

=cut
 
sub find_GenomeHits {
    my ($self,$arg) = @_;

    return $self->feature_Obj->find_GenomeHits($arg);
}
			     

=head2 deleteObj

    Title   : deleteObj
    Usage   : $dbObj->deleteObj
    Function: Call when you are done with this object. Breaks links between objects. Necessary to clean up memory.
    Example : -
    Returns : -
    Args    : -


=cut

sub deleteObj {

  my  $self=shift;
  my $dummy;

  print STDERR "Destroying DB Obj!\n";       
  $self->DESTROY;
  
  foreach my $name ( keys %{$self} ) {
    eval {$dummy = $self->{$name}; 
          $dummy->deleteObj;
    };
    delete $self->{$name};
   }
}


