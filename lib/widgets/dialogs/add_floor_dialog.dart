import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Modal dialog for recording a new floor in an existing building.
///
/// Follows MapX monochrome minimal design tokens.
class AddFloorDialog extends StatefulWidget {
  final String building;
  final bool Function(String name, int floor) exists;

  const AddFloorDialog({
    super.key,
    required this.building,
    required this.exists,
  });

  /// Helper to display this dialog and return the name and floor tuple.
  static Future<({String name, int floor})?> show(
    BuildContext context, {
    required String building,
    required bool Function(String name, int floor) exists,
  }) {
    return showDialog<({String name, int floor})>(
      context: context,
      builder: (_) => AddFloorDialog(
        building: building,
        exists: exists,
      ),
    );
  }

  @override
  State<AddFloorDialog> createState() => _AddFloorDialogState();
}

class _AddFloorDialogState extends State<AddFloorDialog> {
  final _floorController = TextEditingController();
  String? _floorError;

  static const List<int> _quickFloors = [-1, 0, 1, 2, 3, 4];

  @override
  void dispose() {
    _floorController.dispose();
    super.dispose();
  }

  void _submit() {
    final floor = int.tryParse(_floorController.text.trim());
    setState(() {
      _floorError = floor == null
          ? 'Enter a floor number'
          : widget.exists(widget.building, floor)
              ? 'Floor $floor already exists in ${widget.building}'
              : null;
    });
    if (_floorError == null) {
      Navigator.pop(context, (name: widget.building, floor: floor!));
    }
  }

  void _selectQuickFloor(int floor) {
    setState(() {
      _floorController.text = floor.toString();
      _floorError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedFloor = int.tryParse(_floorController.text.trim());

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
      ),
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F4F5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                    ),
                    child: const Icon(
                      CupertinoIcons.layers_alt,
                      size: 22,
                      color: Color(0xFF18181B),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Floor',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFE4E4E7)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                CupertinoIcons.building_2_fill,
                                size: 12,
                                color: Color(0xFF52525B),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  widget.building,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF18181B),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Floor Number Input
              Text(
                'FLOOR LEVEL',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: const Color(0xFF71717A),
                ),
              ),
              const SizedBox(height: 7),
              TextField(
                controller: _floorController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(signed: true),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF18181B),
                ),
                decoration: InputDecoration(
                  hintText: 'e.g., 2 (or 0 for Ground)',
                  prefixIcon: const Icon(
                    CupertinoIcons.number,
                    size: 18,
                    color: Color(0xFF71717A),
                  ),
                  errorText: _floorError,
                ),
              ),
              const SizedBox(height: 10),

              // Quick floor chips
              Row(
                children: [
                  Text(
                    'Quick select: ',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFF71717A),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _quickFloors.map((fl) {
                          final alreadyExists = widget.exists(widget.building, fl);
                          final isSelected = selectedFloor == fl;
                          final label = fl == -1
                              ? 'B1'
                              : fl == 0
                                  ? 'G (0)'
                                  : 'F$fl';
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: alreadyExists
                                  ? null
                                  : () => _selectQuickFloor(fl),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: alreadyExists
                                      ? const Color(0xFFFAFAFA)
                                      : isSelected
                                          ? Colors.black
                                          : const Color(0xFFF4F4F5),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: alreadyExists
                                        ? const Color(0xFFF4F4F5)
                                        : isSelected
                                            ? Colors.black
                                            : const Color(0xFFE4E4E7),
                                  ),
                                ),
                                child: Text(
                                  label,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: alreadyExists
                                        ? const Color(0xFFA1A1AA)
                                        : isSelected
                                            ? Colors.white
                                            : const Color(0xFF27272A),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF27272A),
                        side: const BorderSide(color: Color(0xFFE4E4E7)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      onPressed: _submit,
                      icon: const Icon(CupertinoIcons.play_arrow_solid, size: 14),
                      label: Text(
                        'Start Recording',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
