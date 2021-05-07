#cython: language_level=3

"""
Utils to generate proper sam output and flag information
"""
from __future__ import absolute_import
import re
import click
from . import io_funcs


def echo(*arg):
    click.echo(arg, err=True)


cdef int set_bit(int v, int index, int x):
    """Set the index:th bit of v to 1 if x is truthy, else to 0, and return the new value."""
    cdef int mask
    mask = 1 << index  # Compute mask, an integer with just bit 'index' set.
    v &= ~mask  # Clear the bit indicated by the mask (if x is False)
    if x:
        v |= mask  # If x was True, set the bit indicated by the mask.
    return v


cdef list set_tlen(out):

    pri_1 = out[0][1]
    pri_2 = out[1][1]

    flg1 = pri_1[0]
    flg2 = pri_2[0]

    if flg1 & 12 or flg2 & 12 or pri_1[1] != pri_2[1]:  # Read or mate unmapped, translocation
        tlen1 = 0
        tlen2 = 0
        t1 = 0
        t2 = 0

    else:
        p1_pos = int(pri_1[2])
        p2_pos = int(pri_2[2])

        # Use the end position of the alignment if read is on the reverse strand, or start pos if on the forward
        if flg1 & 16:  # Read rev strand
            aln_end1 = io_funcs.get_align_end_offset(pri_1[4])
            t1 = p1_pos + aln_end1
        else:
            t1 = p1_pos

        if flg2 & 16:
            aln_end2 = io_funcs.get_align_end_offset(pri_2[4])
            t2 = p2_pos + aln_end2
        else:
            t2 = p2_pos

        if t1 <= t2:
            tlen1 = t2 - t1  # Positive
            tlen2 = t1 - t2  # Negative
        else:
            tlen1 = t2 - t1  # Negative
            tlen2 = t1 - t2  # Positive

    pri_1[7] = str(tlen1)
    pri_2[7] = str(tlen2)

    out2 = [(out[0][0], pri_1, out[0][2]), (out[1][0], pri_2, out[1][2])]

    # Set tlen's of supplementary
    for sup_tuple in out[2:]:
        sup_tuple = list(sup_tuple)
        sup_flg = sup_tuple[1][0]
        sup_chrom = sup_tuple[1][1]
        sup_pos = int(sup_tuple[1][2])

        sup_end = io_funcs.get_align_end_offset(sup_tuple[1][4])
        if sup_flg & 16:  # If reverse strand, count to end
            sup_pos += sup_end

        if sup_flg & 64:  # First in pair, mate is second
            other_end = t2
            other_chrom = pri_2[1]
            other_flag = pri_2[0]
        else:
            other_end = t1
            other_chrom = pri_1[1]
            other_flag = pri_1[0]
        # This is a bit of a hack to make the TLEN identical to bwa
        # Make sure they are both on same chromosome
        if sup_chrom == other_chrom:
            if sup_pos < other_end:
                if bool(sup_flg & 16) != bool(other_flag & 16):  # Different strands
                    tlen = other_end - sup_pos
                else:
                    tlen = sup_pos - other_end
            else:
                if bool(sup_flg & 16) != bool(other_flag & 16):  # Different strands
                    tlen = other_end - sup_pos
                else:
                    tlen = sup_pos - other_end

            sup_tuple[1][7] = str(tlen)
        out2.append(tuple(sup_tuple))

    return out2


cdef set_mate_flag(a, b, max_d, read1_rev, read2_rev):

    if not a or not b:  # No alignment, mate unmapped?
        return False, False

    # Make sure chromosome of mate is properly set not "*"
    chrom_a, mate_a = a[2], a[5]
    chrom_b, mate_b = b[2], b[5]
    if chrom_a != mate_b:
        b[5] = chrom_a
    if chrom_b != mate_a:
        a[5] = chrom_b

    aflag = a[0]
    bflag = b[0]

    reverse_A = False
    reverse_B = False

    # If set as not primary, and has been aligned to reverse strand, and primary is mapped on forward
    # the sequence needs to be rev complement
    if aflag & 256:
        if (aflag & 16) and (not read1_rev):
            reverse_A = True
        elif (not aflag & 16) and read1_rev:
            reverse_A = True

    if bflag & 256:
        if (bflag & 16) and (not read2_rev):
            reverse_B = True
        elif (not bflag & 16) and read2_rev:
            reverse_B = True

    # Turn off proper pair flag, might be erroneously set
    aflag = set_bit(aflag, 1, 0)  # Bit index from 0
    bflag = set_bit(bflag, 1, 0)

    # Turn off supplementary pair flag
    aflag = set_bit(aflag, 11, 0)
    bflag = set_bit(bflag, 11, 0)

    # Set paired
    aflag = set_bit(aflag, 0, 1)
    bflag = set_bit(bflag, 0, 1)

    # Set first and second in pair, in case not set
    aflag = set_bit(aflag, 6, 1)
    bflag = set_bit(bflag, 7, 1)

    # Turn off any mate reverse flags, these should be reset
    aflag = set_bit(aflag, 5, 0)
    bflag = set_bit(bflag, 5, 0)

    # If either read is unmapped
    if aflag & 4:
        bflag = set_bit(bflag, 3, 1)  # Position 3, change to 1
    if bflag & 4:
        aflag = set_bit(aflag, 3, 1)

    # If either read on reverse strand
    if aflag & 16:
        bflag = set_bit(bflag, 5, 1)
    if bflag & 16:
        aflag = set_bit(aflag, 5, 1)

    # Set unmapped
    arname = a[1]
    apos = a[2]
    if apos == "0":  # -1 means unmapped
        aflag = set_bit(aflag, 2, 1)
        bflag = set_bit(bflag, 8, 1)

    brname = b[1]
    bpos = b[2]
    if b[2] == "0":
        bflag = set_bit(bflag, 2, 1)
        aflag = set_bit(aflag, 8, 1)

    # Set RNEXT and PNEXT
    a[5] = brname
    a[6] = bpos

    b[5] = arname
    b[6] = apos

    if not (apos == "-1" or bpos == "-1"):

        if arname == brname:
            # Set TLEN
            p1, p2 = int(apos), int(bpos)

            # Set proper-pair flag
            if (aflag & 16 and not bflag & 16) or (not aflag & 16 and bflag & 16):  # Not on same strand

                if abs(p1 - p2) < max_d:
                    # Check for FR or RF orientation
                    if (p1 < p2 and (not aflag & 16) and (bflag & 16)) or (p2 <= p1 and (not bflag & 16) and (aflag & 16)):
                        aflag = set_bit(aflag, 1, 1)
                        bflag = set_bit(bflag, 1, 1)

                        # If proper pair, sometimes the mate-reverse-strand flag is set
                        # this subsequently means the sequence should be reverse complemented
                        if aflag & 16 and not bflag & 32:
                            # Mate-reverse strand not set
                            bflag = set_bit(bflag, 5, 1)
                            # reverse_B = True

                        if not aflag & 16 and bflag & 32:
                            # Mate-reverse should'nt be set
                            bflag = set_bit(bflag, 5, 0)
                            reverse_A = True

                        if bflag & 16 and not aflag & 32:
                            # Mate-reverse strand not set
                            aflag = set_bit(aflag, 5, 1)
                            # reverse_A = True

                        if not bflag & 16 and aflag & 32:
                            # Mate-revsere should'nt be set
                            aflag = set_bit(aflag, 5, 0)
                            reverse_B = True

    a[0] = aflag
    b[0] = bflag

    return reverse_A, reverse_B, a, b


cdef set_supp_flags(sup, pri, ori_primary_reversed, primary_will_be_reversed):

    # Set paired
    supflag = sup[0]
    priflag = pri[0]

    # Set paired and supplementary flag
    if not supflag & 1:
        supflag = set_bit(supflag, 0, 1)
    if not supflag & 2048:
        supflag = set_bit(supflag, 11, 1)

    # If primary is on reverse strand, set the mate reverse strand tag
    if priflag & 16 and not supflag & 32:
        supflag = set_bit(supflag, 5, 1)
    # If primary is on forward srand, turn off mate rev strand
    if not priflag & 16 and supflag & 32:
        supflag = set_bit(supflag, 5, 0)

    # Turn off not-primary-alignment
    if supflag & 256:
        supflag = set_bit(supflag, 8, 0)

    rev_sup = False
    # echo("ori primery rev", ori_primary_reversed, primary_will_be_reversed)
    # echo("primary:", pri)

    if ori_primary_reversed:
        if not supflag & 16:  # Read on forward strand
            rev_sup = True
        # echo("1", rev_sup)
    elif supflag & 16:  # Read on reverse strand
        if not ori_primary_reversed:
            rev_sup = True
        # echo("2", rev_sup)

    # elif not supflag & 16:  # Read on forward strand
    #     if primary_will_be_reversed and not priflag & 16:  # Primary will end up on forward
    #         rev_sup = True  # Old primary on reverse, so needs rev comp
    #     echo("3", rev_sup)

    sup[0] = supflag
    sup[5] = pri[1]
    sup[6] = pri[2]

    return rev_sup


cdef add_sequence_back(item, reverse_me, template):
    # item is the alignment
    cdef int flag = item[0]
    c = re.split(r'(\d+)', item[4])[1:]  # Drop leading empty string

    cdef int i, l
    cdef str opp
    cdef int string_length = 0
    cdef int hard_clip_length = 0
    for i in range(0, len(c), 2):
        l = int(c[i])
        opp = c[i + 1]
        if opp != "D":
            if opp == "H":
                hard_clip_length += l
            else:
                string_length += l
    cdef int cigar_length = string_length + hard_clip_length

    if flag & 64:  # Read1
        seq = template["read1_seq"]
        q = template["read1_q"]

    elif flag & 128:
        seq = template["read2_seq"]
        q = template["read2_q"]

    else:
        seq = template["read1_seq"]  # Unpaired
        q = template["read1_q"]

    if not seq:
        return item

    if len(seq) != string_length:
        if not flag & 2048:  # Always replace primary seq
            if cigar_length == len(seq):
                item[4] = item[4].replace("H", "S")
                item[8] = seq
                if q:
                    item[9] = q
                return item
            else:
                return item  # todo try something here

        elif template["replace_hard"] and q != "*":
            # Sometimes current read had a hard-clip in cigar, but the primary read was not trimmed
            if len(seq) != cigar_length:
                return item  # Cigar length is not set properly by mapper
            # If this is true, reset the Hard-clips with Soft-clips
            item[4] = item[4].replace("H", "S")
            item[8] = seq
            if q:
                item[9] = q
            return item

        return item

    # Occasionally the H is missing, means its impossible to add sequence back in

    if (flag & 64 and len(template["read1_seq"]) > cigar_length) or \
            (flag & 128 and len(template["read2_seq"]) > cigar_length):
        return item

    cdef int start = 0
    cdef int end = 0
    if flag & 64 and template["read1_seq"]:
        name = "read1"
        if template["fq_read1_seq"] != 0:
            end = len(template["fq_read1_seq"])
        else:
            end = len(template["read1_seq"])

    elif flag & 128 and template["read2_seq"]:
        name = "read2"
        if template["fq_read2_seq"] != 0:
            end = len(template["fq_read2_seq"])
        else:
            end = len(template["read2_seq"])
    else:
        return item  # read sequence is None or bad flag

    # Try and replace H with S

    if c[1] == "H" or c[-1] == "H":
        # Replace hard with soft-clips
        if cigar_length == end and template["replace_hard"]:
            item[4] = item[4].replace("H", "S")

        else:
            # Remove seq
            if c[1] == "H":
                start += int(c[0])
            if c[-1] == "H":
                end -= int(c[-2])

    # Might need to collect from the reverse direction; swap end and start
    if flag & 256 or flag & 2048:
        if flag & 64 and template["read1_reverse"] != bool(flag & 16):
            # Different strand to primary, count from end
            new_end = template["read1_length"] - start
            new_start = template["read1_length"] - end
            start = new_start
            end = new_end

        elif flag & 128 and (template["read2_reverse"] != bool(flag & 16)):
            new_end = template["read2_length"] - start
            new_start = template["read2_length"] - end
            start = new_start
            end = new_end

    f_q_name = f"fq_{name}_q"
    # Try and use the primary sequence to replace hard-clips
    if item[9] == "*" or len(item[9]) < abs(end - start) or len(item[9]) == 0:
        if template["replace_hard"] and template["fq_%s_q" % name]:
            key = "fq_"
        else:
            key = ""
        key_name = f"{key}{name}_seq"
        key_name_q = f"{key}{name}_q"
        s = template[key_name][start:end]  # "%s%s_seq" % (key, name)
        q = template[key_name_q][start:end]  # "%s%s_q" % (key, name)

        if len(s) == cigar_length:
            # if reverse_me:
            #     item[8] = io_funcs.reverse_complement(s, len(s))
            #     item[9] = q[::-1]
            # else:
                item[8] = s
                item[9] = q

    # Try and use the supplied fq file to replace the sequence
    elif template[f_q_name] != 0 and len(template[f_q_name]) > len(item[9]):  # "fq_%s_q" % name
        sqn = f"fq_{name}_seq"
        if item[9] in template[f_q_name]:
            item[8] = template[sqn][start:end]
            item[9] = template[f_q_name][start:end]

        elif item[9] in template[f_q_name][::-1]:
            s = io_funcs.reverse_complement(template[sqn], len(template[sqn]))[start:end]
            q = template[f_q_name][::-1][start:end]
            if len(s) == cigar_length:
                item[8] = s
                item[9] = q

        else:
            echo("---")
            echo(item[9], flag)
            echo(name)
            echo(template["read1_q"])
            echo(template["read2_q"])
            echo(item)
            raise ValueError

    if len(item[8]) != cigar_length:
        echo(len(item[8]), cigar_length, len(item[9]), start, end)
        echo(template)
        raise ValueError

    assert len(item[8]) == cigar_length
    return item


cdef list replace_sa_tags(alns):

    if any([i[0] == "sup" for i in alns]):
        sa_tags = {}  # Read1: tag, might be multiple split alignments
        alns2 = []
        for i, j, k in alns:
            # Remove any SA tags in alignment, might be wrong
            j = [item for idx, item in enumerate(j) if idx <= 9 or (idx > 9 and item[:2] != "SA")]
            flag = j[0]
            mapq = j[3]
            nm = 0
            chrom = j[1]
            pos = j[2]
            for tg in j[10:]:
                if tg[:2] == "NM":
                    nm = tg[5:]
                    break

            strand = "-" if flag & 16 else "+"
            cigar = j[4]
            sa = f"{chrom},{pos},{strand},{cigar},{j[0]},{mapq},{nm}"

            key = (flag & 64, 1 if flag & 2048 else 0)
            if key in sa_tags:
                sa_tags[key] += ";" + sa
            else:
                sa_tags[key] = sa
            alns2.append([i, j, k])

        # Now add back in
        out = []
        for i, j, k in alns2:
            flag = j[0]
            key = (flag & 64, 0 if flag & 2048 else 1)
            if key in sa_tags:
                j.insert(14, "SA:Z:" + sa_tags[key])
            out.append((i, j, k))
        return out
    else:
        # Might need to remove SA tags
        return [(i, [item for idx, item in enumerate(j) if idx <= 9 or (idx > 9 and item[:2] != "SA")], ii) for i, j, ii in alns]


cdef list replace_mc_tags(alns):

    # Replace MC mate cigar tag if set
    cdef int i

    a = alns[0][1]
    if alns[1][0] != "sup":
        b = alns[1][1]
    else:
        return alns

    read1_cigar = a[4] if a[0] & 64 else b[4]
    read2_cigar = b[4] if b[0] & 128 else a[4]

    for count, (ps, a, _) in enumerate(alns):
        for i in range(10, len(a)):
            if a[i][0:2] == "MC":
                if a[0] & 64:
                    a[i] = f"MC:Z:{read2_cigar}"
                else:
                    a[i] = f"MC:Z:{read1_cigar}"
                break
    return alns


cpdef list fixsam(dict template):

    sam = [template['inputdata'][i] for i in template['rows']]  # Get chosen rows
    max_d = template['max_d']

    paired = False if template["read2_length"] is 0 else True
    score_mat = template['score_mat']

    out = []
    primary1 = None
    primary2 = None
    rev_A = False
    rev_B = False

    for l in sam:

        l[0] = int(l[0])  # Convert flag to int

        strand = "-1" if l[0] & 16 else "1"
        rid = str(2 if l[0] & 128 else 1)
        key = f"{l[1]}-{l[2]}-{strand}-{rid}"

        if len(score_mat[key]) > 2:
            # Prevent bug where two identical alignments possible
            aln_info_0, aln_info_1 = score_mat[key].pop(0), score_mat[key].pop(0)  # Remove first two items from list
        else:
            aln_info_0, aln_info_1 = score_mat[key]

        xs = int(aln_info_1)

        if l[0] & 2048:
            os = "ZO:i:1"  # refers to "originally supplementary"
        else:
            os = "ZO:i:0"
        l += [
              "ZA:i:" + str(xs),
              "ZP:Z:" + str(round(score_mat["dis_to_next_path"], 0)),
              "ZN:Z:" + str(round(score_mat["dis_to_normal"], 2)),
              "ZS:Z:" + str(round(score_mat["path_score"], 2)),
              "ZM:Z:" + str(round(score_mat["normal_pairings"], 1)),
              os
              ]

        if aln_info_0:
            if rid == "1":
                primary1 = l
            else:
                primary2 = l
        else:
            out.append(['sup', l, False])  # Supplementary, False to decide if rev comp

    if (primary1 is None or primary2 is None) and template["paired_end"]:
        if primary1 is None:
            primary1 = template['inputdata'][0]
            primary1[0] = int(primary1[0])
        if primary2 is None:
            primary2 = template['inputdata'][template['first_read2_index']]  # unmapped
            primary2[0] = int(primary2[0])


    if paired and template["paired_end"]:

        rev_A, rev_B, primary1, primary2 = set_mate_flag(primary1, primary2, max_d, template["read1_reverse"], template["read2_reverse"])

        # Check if supplementary needs reverse complementing
        # echo(rev_A, rev_B)
        # echo("primary1", primary1, template["read1_seq"])
        # echo("primary2", primary2, template["read2_seq"])
        # echo("read1_reverse", template["read1_reverse"], "read2_reverse", template["read2_reverse"])
        for i in range(len(out)):
            # echo("out", out[i][1])
            if out[i][1][0] & 64:  # First in pair  Note primary2 and primary1 order
                revsup = set_supp_flags(out[i][1], primary2, template["read1_reverse"], rev_A)
                # echo("---&64", revsup)
            else:
                revsup = set_supp_flags(out[i][1], primary1, template["read2_reverse"], rev_B)
                # echo("else", revsup)

            if revsup:
                out[i][2] = True
                # echo("revsup", out[i][2])

    if template["paired_end"]:
        out = [('pri', primary1, rev_A), ('pri', primary2, rev_B)] + out
        out = set_tlen(out)

    else:
        out = [('pri', primary1, rev_A)] + out

    # echo("reverse pattern", [(i[0], i[2]) for i in out])
    # Add read seq info back in if necessary, before reverse complementing. Check for hard clips and clip as necessary

    for a_type, aln, reverse_me in out:

        if aln:  # None here means no alignment for primary2

            # Do for all supplementary
            # echo(a_type, "reverseme", reverse_me, aln[8], aln[8] == "*" or "H" in aln[4])
            if aln[8] == "*" or "H" in aln[4]:  # or aln[0] & 2048:  # Sequence might be "*", needs adding back in

                aln = add_sequence_back(aln, reverse_me, template)
                # echo("aln here", aln, template["read1_seq"])
            # elif reverse_me:
                if reverse_me:
                    aln[8] = io_funcs.reverse_complement(str(aln[8]), len(aln[8]))
                    aln[9] = aln[9][::-1]

            # Turn off not primary here
            aln[0] = set_bit(aln[0], 8, 0)

    out = replace_sa_tags(out)
    out = replace_mc_tags(out)

    # Set discordant flag on supplementary, convert flags back to string
    for j in range(len(out)):
        # Set for discordant
        if out[j][0] == "sup":
            rec = out[j][1]
            flag = rec[0]
            # Outside max dist, same chrom, or same strand
            if abs(int(rec[7])) >= max_d or rec[1] != rec[5] or bool(flag & 16) == bool(flag & 32):
                flag = set_bit(flag, 1, 0)
                out[j][1][0] = flag

        out[j][1][0] = str(out[j][1][0])

    return [i[1] for i in out if i[1] != 0]

