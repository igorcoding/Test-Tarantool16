use Proc::ProcessTable;
use 5.010;

 my $t = new Proc::ProcessTable;

 my $pid = 740;
 for $p ( @{$t->table} ){
 	if ($p->pid == $pid) {
 		say($p->cmndline);
 	}
 }
